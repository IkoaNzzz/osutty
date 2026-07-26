import Darwin
import Foundation

struct SidecarGitSnapshot: Equatable, Sendable {
    let repositoryRoot: URL
    let branch: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let remoteURL: String?
    let insertions: Int
    let deletions: Int
    let changes: [SidecarGitChange]
    let stagedChanges: [SidecarGitChange]
    let unstagedChanges: [SidecarGitChange]
    let availablePaths: Set<String>

    init(
        repositoryRoot: URL,
        branch: String,
        upstream: String?,
        ahead: Int,
        behind: Int,
        remoteURL: String?,
        insertions: Int,
        deletions: Int,
        changes: [SidecarGitChange],
        availablePaths: Set<String>
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.remoteURL = remoteURL
        self.insertions = insertions
        self.deletions = deletions
        self.changes = changes
        self.stagedChanges = changes.filter { $0.isStaged && !$0.isConflict }
        self.unstagedChanges = changes.filter(\.isUnstaged)
        self.availablePaths = availablePaths
    }

    func replacingRemoteURL(_ remoteURL: String?) -> Self {
        .init(
            repositoryRoot: repositoryRoot,
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            remoteURL: remoteURL,
            insertions: insertions,
            deletions: deletions,
            changes: changes,
            availablePaths: availablePaths
        )
    }
}

struct SidecarGitChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let indexStatus: Character
    let worktreeStatus: Character
    let isUntracked: Bool
    let isConflict: Bool

    var id: String { "\(path):\(indexStatus):\(worktreeStatus)" }
    var isStaged: Bool { indexStatus != "." && indexStatus != "?" }
    var isUnstaged: Bool { worktreeStatus != "." || isUntracked || isConflict }

    var displayStatus: String {
        if isConflict { return "!" }
        if isUntracked { return "?" }
        return String(indexStatus != "." ? indexStatus : worktreeStatus)
    }

    var operationPaths: [String] {
        guard let originalPath, originalPath != path else { return [path] }
        return [originalPath, path]
    }
}

enum SidecarGitOperation: Sendable {
    case stage(paths: [String])
    case unstage(paths: [String])
    case stageAll
    case unstageAll
    case commit(message: String)
    case fetch
    case pull
    case push
    case merge(reference: String)
    case rebase(reference: String)
}

struct SidecarGitError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

/// Runs Git only while the Git panel (or its commit window) is active.
///
/// The actor serializes status and mutation commands so an automatic refresh
/// cannot race a stage or commit operation.
actor SidecarGitService {
    private static let diffByteLimit = 1_048_576
    private static let diffLineLimit = 20_000
    private static let maximumRootCacheCount = 32
    private static let maximumDiffCacheCount = 8
    private static let missingRepositoryCacheDuration: TimeInterval = 10
    private static let remoteCacheDuration: TimeInterval = 30
    private static let diffCacheDuration: TimeInterval = 5

    private let runner = SidecarGitCommandRunner()
    private var rootCache: [URL: SidecarGitRootCacheEntry] = [:]
    private var repositoryCache: [URL: SidecarGitRepositoryCache] = [:]

    func snapshot(workingDirectory: URL) async throws -> SidecarGitSnapshot? {
        let workingDirectory = workingDirectory.standardizedFileURL
        let now = Date()
        let cachedRoot = rootCache[workingDirectory]
        if let cachedRoot,
           cachedRoot.root == nil,
           now.timeIntervalSince(cachedRoot.checkedAt)
            < Self.missingRepositoryCacheDuration {
            return nil
        }

        let cachedRepositoryRoot = cachedRoot?.root
        let cachedRepository = cachedRepositoryRoot.flatMap { repositoryCache[$0] }
        let transaction: SidecarGitSnapshotTransaction?
        do {
            transaction = try await runner.submit { command -> SidecarGitSnapshotTransaction? in
                let root: URL
                if let cachedRoot = cachedRepositoryRoot {
                    root = cachedRoot
                } else {
                    let rootResult = try command.run(
                        ["-C", workingDirectory.path, "rev-parse", "--show-toplevel"],
                        readOnly: true
                    )
                    guard rootResult.status == 0 else { return nil }

                    let rootPath = rootResult.output.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !rootPath.isEmpty else { return nil }
                    root = URL(fileURLWithPath: rootPath, isDirectory: true)
                        .standardizedFileURL
                }

                let matchingCache = cachedRepository?.root == root
                    ? cachedRepository
                    : nil
                let statusResult = try command.run(
                    [
                        "-C", root.path,
                        "status",
                        "--porcelain=v2",
                        "--branch",
                        "--show-stash",
                        "--untracked-files=all",
                        "-z",
                    ],
                    readOnly: true
                )
                try Self.requireSuccess(statusResult)
                let parsed = SidecarGitParser.status(statusResult.data)
                let fingerprint = Self.statusFingerprint(
                    root: root,
                    statusData: statusResult.data,
                    changes: parsed.changes
                )

                let shouldRefreshRemote = matchingCache.map {
                    now.timeIntervalSince($0.remoteCheckedAt)
                        >= Self.remoteCacheDuration
                } ?? true
                let remoteURL: String?
                let remoteCheckedAt: Date
                if shouldRefreshRemote {
                    let remoteResult = try command.run(
                        ["-C", root.path, "remote", "get-url", "origin"],
                        readOnly: true
                    )
                    let value = remoteResult.status == 0
                        ? remoteResult.output.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        : nil
                    remoteURL = value?.isEmpty == false ? value : nil
                    remoteCheckedAt = now
                } else {
                    remoteURL = matchingCache?.snapshot.remoteURL
                    remoteCheckedAt = matchingCache?.remoteCheckedAt ?? now
                }

                if let matchingCache,
                   matchingCache.fingerprint == fingerprint {
                    return .init(
                        root: root,
                        fingerprint: fingerprint,
                        snapshot: matchingCache.snapshot.replacingRemoteURL(remoteURL),
                        remoteCheckedAt: remoteCheckedAt
                    )
                }

                let headResult = try command.run(
                    ["-C", root.path, "rev-parse", "--verify", "HEAD"],
                    readOnly: true
                )
                let diffArguments = headResult.status == 0
                    ? ["-C", root.path, "diff", "--numstat", "HEAD"]
                    : ["-C", root.path, "diff", "--cached", "--numstat"]
                let diffResult = try command.run(diffArguments, readOnly: true)
                let diff = diffResult.status == 0
                    ? SidecarGitParser.numstat(diffResult.output)
                    : (0, 0)
                let availablePaths = Set(parsed.changes.lazy.compactMap { change in
                    let path = root.appendingPathComponent(change.path).path
                    return FileManager.default.fileExists(atPath: path)
                        ? change.path
                        : nil
                })

                let snapshot = SidecarGitSnapshot(
                    repositoryRoot: root,
                    branch: parsed.branch,
                    upstream: parsed.upstream,
                    ahead: parsed.ahead,
                    behind: parsed.behind,
                    remoteURL: remoteURL,
                    insertions: diff.0,
                    deletions: diff.1,
                    changes: parsed.changes,
                    availablePaths: availablePaths
                )
                return .init(
                    root: root,
                    fingerprint: fingerprint,
                    snapshot: snapshot,
                    remoteCheckedAt: remoteCheckedAt
                )
            }
        } catch {
            rootCache[workingDirectory] = nil
            throw error
        }

        guard let transaction else {
            rootCache[workingDirectory] = .init(root: nil, checkedAt: now)
            trimRootCache()
            return nil
        }

        rootCache[workingDirectory] = .init(
            root: transaction.root,
            checkedAt: now
        )
        trimRootCache()

        var cache = repositoryCache[transaction.root]
            ?? .init(
                root: transaction.root,
                fingerprint: transaction.fingerprint,
                snapshot: transaction.snapshot,
                remoteCheckedAt: transaction.remoteCheckedAt
            )
        if cache.fingerprint != transaction.fingerprint {
            cache.diffCache.removeAll(keepingCapacity: true)
        }
        cache.fingerprint = transaction.fingerprint
        cache.snapshot = transaction.snapshot
        cache.remoteCheckedAt = transaction.remoteCheckedAt
        repositoryCache[transaction.root] = cache
        return transaction.snapshot
    }

    func perform(_ operation: SidecarGitOperation, repository: URL) async throws {
        try await runner.submit { command in
            let arguments: [String]
            let input: Data?

            switch operation {
            case .stage(let paths):
                guard !paths.isEmpty else { return }
                arguments = ["-C", repository.path, "add", "--"] + paths
                input = nil

            case .unstage(let paths):
                guard !paths.isEmpty else { return }
                if try Self.hasHead(repository: repository, command: command) {
                    arguments = ["-C", repository.path, "reset", "-q", "HEAD", "--"] + paths
                } else {
                    arguments = ["-C", repository.path, "rm", "--cached", "-q", "--"] + paths
                }
                input = nil

            case .stageAll:
                arguments = ["-C", repository.path, "add", "-A"]
                input = nil

            case .unstageAll:
                if try Self.hasHead(repository: repository, command: command) {
                    arguments = ["-C", repository.path, "reset", "-q", "HEAD", "--", "."]
                } else {
                    arguments = ["-C", repository.path, "rm", "--cached", "-r", "-q", "--", "."]
                }
                input = nil

            case .commit(let message):
                let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw SidecarGitError(message: "Enter a commit message.")
                }
                arguments = ["-C", repository.path, "commit", "--file=-"]
                input = Data((normalized + "\n").utf8)

            case .fetch:
                arguments = ["-C", repository.path, "fetch"]
                input = nil

            case .pull:
                arguments = ["-C", repository.path, "pull", "--ff-only"]
                input = nil

            case .push:
                arguments = ["-C", repository.path, "push"]
                input = nil

            case .merge(let reference):
                arguments = ["-C", repository.path, "merge", "--", reference]
                input = nil

            case .rebase(let reference):
                arguments = ["-C", repository.path, "rebase", "--", reference]
                input = nil
            }

            try Self.requireSuccess(command.run(
                arguments,
                input: input,
                readOnly: false
            ))
        }
        repositoryCache[repository.standardizedFileURL] = nil
    }

    func diff(
        for change: SidecarGitChange,
        repository: URL,
        isStaged: Bool
    ) async throws -> String {
        let repository = repository.standardizedFileURL
        let key = SidecarGitDiffCacheKey(
            change: change,
            isStaged: isStaged,
            contentFingerprint: Self.diffFingerprint(
                change: change,
                repository: repository,
                isStaged: isStaged
            )
        )
        let now = Date()
        if var cache = repositoryCache[repository],
           let entry = cache.diffCache[key],
           now.timeIntervalSince(entry.createdAt) < Self.diffCacheDuration {
            cache.diffCache[key] = .init(
                value: entry.value,
                createdAt: entry.createdAt,
                lastAccessedAt: now
            )
            repositoryCache[repository] = cache
            return entry.value
        }

        let fingerprint = repositoryCache[repository]?.fingerprint
        let output = try await runner.submit { command in
            let arguments: [String]
            let successfulStatuses: Set<Int32>

            if change.isUntracked, !isStaged {
                arguments = [
                    "--no-pager",
                    "-C", repository.path,
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--no-index",
                    "--",
                    "/dev/null",
                    change.path,
                ]
                // `git diff --no-index` returns 1 when files differ.
                successfulStatuses = [0, 1]
            } else {
                var paths = [change.path]
                if let originalPath = change.originalPath, originalPath != change.path {
                    paths.insert(originalPath, at: 0)
                }

                arguments = [
                    "--no-pager",
                    "-C", repository.path,
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--unified=3",
                ] + (isStaged ? ["--cached"] : []) + ["--"] + paths
                successfulStatuses = [0]
            }

            let result = try command.run(
                arguments,
                readOnly: true,
                maxOutputBytes: Self.diffByteLimit
            )
            guard result.isTruncated || successfulStatuses.contains(result.status) else {
                try Self.requireSuccess(result)
                return ""
            }

            let output = Self.diffPreview(result)
            return output.isEmpty ? "No diff available." : output
        }

        if var cache = repositoryCache[repository],
           cache.fingerprint == fingerprint {
            cache.diffCache[key] = .init(
                value: output,
                createdAt: now,
                lastAccessedAt: now
            )
            if cache.diffCache.count > Self.maximumDiffCacheCount,
               let oldestKey = cache.diffCache.min(by: {
                   $0.value.lastAccessedAt < $1.value.lastAccessedAt
               })?.key {
                cache.diffCache[oldestKey] = nil
            }
            repositoryCache[repository] = cache
        }
        return output
    }

    private func trimRootCache() {
        while rootCache.count > Self.maximumRootCacheCount,
              let oldest = rootCache.min(by: {
                  $0.value.checkedAt < $1.value.checkedAt
              })?.key {
            rootCache[oldest] = nil
        }
    }

    private nonisolated static func statusFingerprint(
        root: URL,
        statusData: Data,
        changes: [SidecarGitChange]
    ) -> SidecarGitStatusFingerprint {
        let paths = Set(changes.flatMap(\.operationPaths))
        return .init(
            statusData: statusData,
            files: paths
                .map { fileFingerprint(root.appendingPathComponent($0)) }
                .sorted { $0.path < $1.path },
            index: fileFingerprint(gitDirectory(root).appendingPathComponent("index"))
        )
    }

    private nonisolated static func diffFingerprint(
        change: SidecarGitChange,
        repository: URL,
        isStaged: Bool
    ) -> [SidecarGitFileFingerprint] {
        if isStaged {
            return [
                fileFingerprint(
                    gitDirectory(repository).appendingPathComponent("index")
                ),
            ]
        }
        return change.operationPaths
            .map { fileFingerprint(repository.appendingPathComponent($0)) }
            .sorted { $0.path < $1.path }
    }

    private nonisolated static func gitDirectory(_ repository: URL) -> URL {
        let dotGit = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: dotGit.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return dotGit
        }

        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              contents.hasPrefix("gitdir:") else {
            return dotGit
        }
        let path = contents
            .dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: path, relativeTo: repository)
        return url.standardizedFileURL
    }

    private nonisolated static func fileFingerprint(
        _ url: URL
    ) -> SidecarGitFileFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return .init(
            path: url.standardizedFileURL.path,
            size: attributes?[.size] as? UInt64,
            modifiedAt: attributes?[.modificationDate] as? Date
        )
    }

    private nonisolated static func diffPreview(_ result: GitResult) -> String {
        let lines = result.output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let isLineTruncated = lines.count > diffLineLimit
        var output = lines
            .prefix(diffLineLimit)
            .joined(separator: "\n")

        if result.isTruncated || isLineTruncated {
            if !output.isEmpty {
                output += "\n\n"
            }
            output += "… Diff preview truncated to 1 MiB / 20,000 lines …"
        }
        return output
    }

    private nonisolated static func hasHead(
        repository: URL,
        command: SidecarGitCommandExecution
    ) throws -> Bool {
        try command.run(
            ["-C", repository.path, "rev-parse", "--verify", "HEAD"],
            readOnly: true
        ).status == 0
    }

    private nonisolated static func requireSuccess(_ result: GitResult) throws {
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SidecarGitError(
                message: message.isEmpty ? "Git exited with status \(result.status)." : message
            )
        }
    }
}

private struct SidecarGitRootCacheEntry: Sendable {
    let root: URL?
    let checkedAt: Date
}

private struct SidecarGitRepositoryCache: Sendable {
    let root: URL
    var fingerprint: SidecarGitStatusFingerprint
    var snapshot: SidecarGitSnapshot
    var remoteCheckedAt: Date
    var diffCache: [SidecarGitDiffCacheKey: SidecarGitDiffCacheEntry] = [:]
}

private struct SidecarGitSnapshotTransaction: Sendable {
    let root: URL
    let fingerprint: SidecarGitStatusFingerprint
    let snapshot: SidecarGitSnapshot
    let remoteCheckedAt: Date
}

private struct SidecarGitDiffCacheKey: Hashable, Sendable {
    let change: SidecarGitChange
    let isStaged: Bool
    let contentFingerprint: [SidecarGitFileFingerprint]
}

private struct SidecarGitDiffCacheEntry: Sendable {
    let value: String
    let createdAt: Date
    let lastAccessedAt: Date
}

private struct SidecarGitStatusFingerprint: Equatable, Sendable {
    let statusData: Data
    let files: [SidecarGitFileFingerprint]
    let index: SidecarGitFileFingerprint
}

private struct SidecarGitFileFingerprint: Hashable, Sendable {
    let path: String
    let size: UInt64?
    let modifiedAt: Date?
}

/// Executes complete Git transactions on one utility queue.
///
/// Keeping the queue outside the actor prevents a synchronous `Process` wait
/// from occupying a cooperative Swift executor. The cancellation token can
/// terminate the active process even while the queue is blocked draining its
/// output, and queued transactions observe cancellation before starting.
final class SidecarGitCommandRunner: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.ikoanzzz.osutty.sidecar.git",
        qos: .utility
    )

    func submit<Value: Sendable>(
        _ body: @escaping @Sendable (SidecarGitCommandExecution) throws -> Value
    ) async throws -> Value {
        let execution = SidecarGitCommandExecution()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                queue.async {
                    defer { execution.complete() }
                    do {
                        try execution.checkStopped()
                        continuation.resume(returning: try body(execution))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            execution.cancel(reason: .cancelled)
        }
    }
}

final class SidecarGitCommandExecution: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    private var process: Process?
    private var stopReason: StopReason?
    private var isComplete = false

    func run(
        _ arguments: [String],
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        input: Data? = nil,
        readOnly: Bool,
        timeout: TimeInterval? = nil,
        maxOutputBytes: Int? = nil
    ) throws -> GitResult {
        try checkStopped()

        let process = Process()
        let output = Pipe()
        let standardInput = input == nil ? nil : Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        if let standardInput {
            process.standardInput = standardInput
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.qualityOfService = .utility

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["LC_ALL"] = "C"
        if readOnly {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }
        process.environment = environment

        guard attach(process) else {
            try checkStopped()
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            detach(process)
            try checkStopped()
            return .init(status: -1, data: Data(error.localizedDescription.utf8))
        }

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.cancel(reason: .timedOut)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + (timeout ?? (readOnly ? 15 : 60)),
            execute: timeoutItem
        )

        if isStopped {
            process.terminate()
        }

        if let input, let standardInput {
            standardInput.fileHandleForWriting.write(input)
            try? standardInput.fileHandleForWriting.close()
        }

        let (data, isTruncated) = readOutput(
            output.fileHandleForReading,
            maxBytes: maxOutputBytes,
            process: process
        )
        process.waitUntilExit()
        timeoutItem.cancel()
        detach(process)
        try checkStopped()

        return .init(
            status: process.terminationStatus,
            data: data,
            isTruncated: isTruncated
        )
    }

    func checkStopped() throws {
        let reason = withLock { stopReason }
        switch reason {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw SidecarGitError(message: "Git command timed out.")
        case nil:
            return
        }
    }

    func cancel(reason: StopReason) {
        let activeProcess: Process? = withLock {
            guard !isComplete else { return nil }
            if stopReason == nil {
                stopReason = reason
            }
            return process
        }

        if let activeProcess, activeProcess.isRunning {
            terminateProcessTree(activeProcess)
        }
    }

    private func readOutput(
        _ handle: FileHandle,
        maxBytes: Int?,
        process: Process
    ) -> (Data, Bool) {
        let chunkSize = 64 * 1_024
        var data = Data()
        var isTruncated = false
        if let maxBytes {
            data.reserveCapacity(maxBytes)
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }

            if let maxBytes {
                let remaining = max(0, maxBytes - data.count)
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                if !isTruncated, chunk.count > remaining {
                    isTruncated = true
                    terminateProcessTree(process)
                }
            } else {
                data.append(chunk)
            }
        }

        return (data, isTruncated)
    }

    private func terminateProcessTree(_ process: Process) {
        let identities = processTree(rootPID: process.processIdentifier, limit: 128)
        guard !identities.isEmpty else {
            process.terminate()
            return
        }
        signal(identities.reversed(), with: SIGTERM)

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(500)
        ) {
            self.signal(identities.reversed(), with: SIGKILL)
        }
    }

    private func processTree(rootPID: pid_t, limit: Int) -> [GitProcessIdentity] {
        var pending = [rootPID]
        var seen = Set<pid_t>()
        var result: [GitProcessIdentity] = []

        while let pid = pending.first, result.count < limit {
            pending.removeFirst()
            guard pid > 0, seen.insert(pid).inserted,
                  let identity = processIdentity(pid: pid) else {
                continue
            }
            result.append(identity)

            var children = [pid_t](repeating: 0, count: 64)
            let childCount = children.withUnsafeMutableBytes {
                proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
            }
            if childCount > 0 {
                pending.append(contentsOf: children.prefix(min(
                    Int(childCount),
                    children.count
                )).filter { $0 > 0 })
            }
        }

        return result
    }

    private func processIdentity(pid: pid_t) -> GitProcessIdentity? {
        var info = proc_bsdinfo()
        let byteCount = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return .init(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private func signal<C: Collection>(
        _ identities: C,
        with signal: Int32
    ) where C.Element == GitProcessIdentity {
        for identity in identities where processIdentity(pid: identity.pid) == identity {
            Darwin.kill(identity.pid, signal)
        }
    }

    func complete() {
        withLock {
            isComplete = true
            process = nil
        }
    }

    private var isStopped: Bool {
        withLock { stopReason != nil }
    }

    private func attach(_ process: Process) -> Bool {
        withLock {
            guard stopReason == nil, !isComplete else { return false }
            self.process = process
            return true
        }
    }

    private func detach(_ process: Process) {
        withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum SidecarGitParser {
    static func status(_ data: Data) -> SidecarParsedGitStatus {
        let records = data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        var result = SidecarParsedGitStatus()
        var index = 0

        while index < records.count {
            let record = records[index]
            defer { index += 1 }

            if record.hasPrefix("# branch.head ") {
                result.branch = String(record.dropFirst("# branch.head ".count))
                continue
            }
            if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
                continue
            }
            if record.hasPrefix("# branch.ab ") {
                let values = record.split(separator: " ")
                for value in values {
                    if value.hasPrefix("+") {
                        result.ahead = Int(value.dropFirst()) ?? 0
                    } else if value.hasPrefix("-") {
                        result.behind = Int(value.dropFirst()) ?? 0
                    }
                }
                continue
            }

            if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8)
                guard fields.count == 9 else { continue }
                result.changes.append(change(
                    status: fields[1],
                    path: String(fields[8])
                ))
                continue
            }

            if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9)
                guard fields.count == 10 else { continue }
                let originalPath = index + 1 < records.count ? records[index + 1] : nil
                index += 1
                result.changes.append(change(
                    status: fields[1],
                    path: String(fields[9]),
                    originalPath: originalPath
                ))
                continue
            }

            if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10)
                guard fields.count == 11 else { continue }
                result.changes.append(change(
                    status: fields[1],
                    path: String(fields[10]),
                    conflict: true
                ))
                continue
            }

            if record.hasPrefix("? ") {
                result.changes.append(.init(
                    path: String(record.dropFirst(2)),
                    originalPath: nil,
                    indexStatus: "?",
                    worktreeStatus: "?",
                    isUntracked: true,
                    isConflict: false
                ))
            }
        }

        if result.branch == "(detached)" {
            result.branch = "Detached HEAD"
        }
        return result
    }

    private static func change(
        status: Substring,
        path: String,
        originalPath: String? = nil,
        conflict: Bool = false
    ) -> SidecarGitChange {
        let characters = Array(status)
        let indexStatus = characters.first ?? "."
        let worktreeStatus = characters.dropFirst().first ?? "."

        return .init(
            path: path,
            originalPath: originalPath,
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus,
            isUntracked: false,
            isConflict: conflict
        )
    }

    static func numstat(_ output: String) -> (Int, Int) {
        output.split(separator: "\n").reduce(into: (0, 0)) { result, line in
            let values = line.split(separator: "\t", maxSplits: 2)
            guard values.count >= 2 else { return }
            result.0 += Int(values[0]) ?? 0
            result.1 += Int(values[1]) ?? 0
        }
    }
}

struct GitResult: Sendable {
    let status: Int32
    let data: Data
    let isTruncated: Bool

    init(status: Int32, data: Data, isTruncated: Bool = false) {
        self.status = status
        self.data = data
        self.isTruncated = isTruncated
    }

    var output: String {
        if let output = String(bytes: data, encoding: .utf8) {
            return output
        }

        var validPrefix = data
        for _ in 0..<3 where !validPrefix.isEmpty {
            validPrefix.removeLast()
            if let output = String(bytes: validPrefix, encoding: .utf8) {
                return output
            }
        }
        return ""
    }
}

private struct GitProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct SidecarParsedGitStatus {
    var branch = "HEAD"
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [SidecarGitChange] = []
}
