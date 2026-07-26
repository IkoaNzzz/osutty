import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

struct SidecarOutlineParserTests {
    @Test func parsesCompleteRecordsAndIgnoresTruncatedTail() {
        var data = Data()
        appendRecord(row: 7, flags: 1, command: "git status", to: &data)
        appendRecord(row: 42, flags: 0, command: "swift test", to: &data)
        data.append(contentsOf: [1, 2, 3])

        let commands = SidecarOutlineParser.parse(data)

        #expect(commands.count == 2)
        #expect(commands[0].row == 7)
        #expect(commands[0].hasFollowingPrompt)
        #expect(commands[0].command == "git status")
        #expect(commands[1].row == 42)
        #expect(!commands[1].hasFollowingPrompt)
        #expect(commands[1].command == "swift test")
    }

    @Test func rejectsInvalidUTF8WithoutLosingFollowingRecords() {
        var data = Data()
        appendRecord(row: 1, flags: 1, bytes: [0xFF], to: &data)
        appendRecord(row: 2, flags: 0, command: "pwd", to: &data)

        let commands = SidecarOutlineParser.parse(data)

        #expect(commands.count == 1)
        #expect(commands[0].row == 2)
        #expect(commands[0].command == "pwd")
    }

    private func appendRecord(
        row: UInt32,
        flags: UInt8,
        command: String,
        to data: inout Data
    ) {
        appendRecord(row: row, flags: flags, bytes: Array(command.utf8), to: &data)
    }

    private func appendRecord(
        row: UInt32,
        flags: UInt8,
        bytes: [UInt8],
        to data: inout Data
    ) {
        appendLittleEndian(row, to: &data)
        data.append(flags)
        appendLittleEndian(UInt32(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

struct SidecarGitParserTests {
    @Test func parsesBranchChangesRenameConflictAndUntrackedRecords() {
        let records = [
            "# branch.head feature/sidecar",
            "# branch.upstream origin/feature/sidecar",
            "# branch.ab +2 -3",
            "1 .M N... 100644 100644 100644 abc abc Sources/App.swift",
            "1 AD N... 100644 100644 100644 abc abc deleted-after-add.txt",
            "2 R. N... 100644 100644 100644 abc abc R100 Sources/New Name.swift",
            "Sources/Old Name.swift",
            "u UU N... 100644 100644 100644 100644 abc abc abc conflict.txt",
            "? untracked file.txt",
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)

        let result = SidecarGitParser.status(data)

        #expect(result.branch == "feature/sidecar")
        #expect(result.upstream == "origin/feature/sidecar")
        #expect(result.ahead == 2)
        #expect(result.behind == 3)
        #expect(result.changes.count == 5)
        #expect(result.changes[0].path == "Sources/App.swift")
        #expect(result.changes[0].isUnstaged)
        #expect(!result.changes[1].isConflict)
        #expect(result.changes[2].originalPath == "Sources/Old Name.swift")
        #expect(result.changes[2].operationPaths == [
            "Sources/Old Name.swift",
            "Sources/New Name.swift",
        ])
        #expect(result.changes[3].isConflict)
        #expect(result.changes[4].isUntracked)
    }

    @Test func normalizesDetachedHeadAndTotalsTextNumstatOnly() {
        let status = SidecarGitParser.status(Data("# branch.head (detached)\0".utf8))
        let totals = SidecarGitParser.numstat(
            "12\t3\tSources/App.swift\n-\t-\tAssets/image.png\n5\t7\tREADME.md\n"
        )

        #expect(status.branch == "Detached HEAD")
        #expect(totals.0 == 17)
        #expect(totals.1 == 10)
    }
}

struct SidecarGitServiceTests {
    @Test func reportsEveryFileInsideUntrackedDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try initializeRepository(root)
        let generated = root.appending(path: "Generated", directoryHint: .isDirectory)
        let nested = generated.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: generated.appending(path: "one.txt"))
        try Data("two\n".utf8).write(to: nested.appending(path: "two.swift"))

        let service = SidecarGitService()
        let snapshot = try #require(try await service.snapshot(workingDirectory: root))

        #expect(Set(snapshot.unstagedChanges.map(\.path)) == [
            "Generated/Nested/two.swift",
            "Generated/one.txt",
        ])
    }

    @Test func snapshotsAndMutatesAnIsolatedRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-q", "--initial-branch=main"], in: root)
        try runGit(["config", "user.name", "Ghostty Sidecar Test"], in: root)
        try runGit(["config", "user.email", "sidecar@example.invalid"], in: root)

        let file = root.appending(path: "README.md")
        try Data("initial\n".utf8).write(to: file)

        let service = SidecarGitService()
        try await service.perform(.stageAll, repository: root)
        var snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.stagedChanges.map(\.path) == ["README.md"])
        #expect(snapshot.insertions == 1)

        try await service.perform(.unstage(paths: ["README.md"]), repository: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.unstagedChanges.map(\.path) == ["README.md"])

        try await service.perform(.stageAll, repository: root)
        try await service.perform(.unstageAll, repository: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.unstagedChanges.map(\.path) == ["README.md"])

        try await service.perform(.stageAll, repository: root)
        try await service.perform(.commit(message: "Initial commit"), repository: root)

        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.branch == "main")
        #expect(snapshot.changes.isEmpty)

        try Data("changed\n".utf8).write(to: file)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.unstagedChanges.map(\.path) == ["README.md"])
        #expect(snapshot.insertions == 1)

        // The porcelain status remains `.M`, so cached snapshots must also
        // consider file metadata before reusing diff statistics.
        try Data("changed\nsecond\n".utf8).write(to: file)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.insertions == 2)

        try await service.perform(.stage(paths: ["README.md"]), repository: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.stagedChanges.map(\.path) == ["README.md"])

        try await service.perform(.unstage(paths: ["README.md"]), repository: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.unstagedChanges.map(\.path) == ["README.md"])

        let unstagedChange = try #require(snapshot.unstagedChanges.first)
        let unstagedDiff = try await service.diff(
            for: unstagedChange,
            repository: root,
            isStaged: false
        )
        #expect(unstagedDiff.contains("-initial"))
        #expect(unstagedDiff.contains("+changed"))

        try Data("changed again\n".utf8).write(to: file)
        let refreshedDiff = try await service.diff(
            for: unstagedChange,
            repository: root,
            isStaged: false
        )
        #expect(refreshedDiff.contains("+changed again"))

        let untrackedFile = root.appending(path: "notes.txt")
        try Data("untracked\n".utf8).write(to: untrackedFile)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        let untrackedChange = try #require(
            snapshot.unstagedChanges.first { $0.path == "notes.txt" }
        )
        let untrackedDiff = try await service.diff(
            for: untrackedChange,
            repository: root,
            isStaged: false
        )
        #expect(untrackedDiff.contains("+untracked"))
    }

    @Test func reportsConflictDetachedHeadAndMissingRemoteFromARealRepository() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try initializeRepository(root)
        let file = root.appending(path: "conflict.txt")
        try Data("base\n".utf8).write(to: file)
        try runGit(["add", "conflict.txt"], in: root)
        try runGit(["commit", "-q", "-m", "base"], in: root)

        try runGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic\n".utf8).write(to: file)
        try runGit(["commit", "-q", "-am", "topic"], in: root)

        try runGit(["switch", "-q", "main"], in: root)
        try Data("main\n".utf8).write(to: file)
        try runGit(["commit", "-q", "-am", "main"], in: root)
        let mergeStatus = try runGit(
            ["merge", "topic"],
            in: root,
            expectsSuccess: false
        )
        #expect(mergeStatus != 0)

        let service = SidecarGitService()
        var snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.changes.count == 1)
        #expect(snapshot.changes[0].path == "conflict.txt")
        #expect(snapshot.changes[0].isConflict)
        #expect(snapshot.stagedChanges.isEmpty)
        #expect(snapshot.unstagedChanges.map(\.path) == ["conflict.txt"])
        #expect(snapshot.remoteURL == nil)
        #expect(snapshot.upstream == nil)

        try runGit(["merge", "--abort"], in: root)
        try runGit(["switch", "-q", "--detach", "HEAD"], in: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.branch == "Detached HEAD")
        #expect(snapshot.upstream == nil)
    }

    @Test func stagesAndUnstagesBothSidesOfARename() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try initializeRepository(root)
        try Data("original\n".utf8).write(to: root.appending(path: "old.txt"))
        try runGit(["add", "old.txt"], in: root)
        try runGit(["commit", "-q", "-m", "initial"], in: root)
        try runGit(["mv", "old.txt", "new.txt"], in: root)

        let service = SidecarGitService()
        var snapshot = try #require(try await service.snapshot(workingDirectory: root))
        let rename = try #require(snapshot.stagedChanges.first)
        #expect(rename.originalPath == "old.txt")
        #expect(rename.path == "new.txt")

        try await service.perform(.unstage(paths: rename.operationPaths), repository: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.stagedChanges.isEmpty)

        try await service.perform(.stage(paths: rename.operationPaths), repository: root)
        snapshot = try #require(try await service.snapshot(workingDirectory: root))
        #expect(snapshot.stagedChanges.count == 1)
        #expect(snapshot.stagedChanges.first?.originalPath == "old.txt")
        #expect(snapshot.stagedChanges.first?.path == "new.txt")
    }

    @Test func truncatesLargeDiffPreviews() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try initializeRepository(root)
        let largeFile = root.appending(path: "large.txt")
        try Data(repeating: 120, count: 1_500_000).write(to: largeFile)

        let service = SidecarGitService()
        let snapshot = try #require(try await service.snapshot(workingDirectory: root))
        let change = try #require(snapshot.unstagedChanges.first)
        let diff = try await service.diff(
            for: change,
            repository: root,
            isStaged: false
        )

        #expect(diff.contains("Diff preview truncated"))
        #expect(diff.utf8.count < 1_050_000)
    }

    @Test func reportsAheadAndBehindAgainstALocalRemote() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let remote = container.appending(path: "remote.git", directoryHint: .isDirectory)
        let primary = container.appending(path: "primary", directoryHint: .isDirectory)
        let peer = container.appending(path: "peer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)

        try runGit(
            ["init", "--bare", "-q", "--initial-branch=main", remote.path],
            in: container
        )
        try initializeRepository(primary)
        try Data("base\n".utf8).write(to: primary.appending(path: "base.txt"))
        try runGit(["add", "base.txt"], in: primary)
        try runGit(["commit", "-q", "-m", "base"], in: primary)
        try runGit(["remote", "add", "origin", remote.path], in: primary)
        try runGit(["push", "-q", "-u", "origin", "main"], in: primary)

        try runGit(["clone", "-q", remote.path, peer.path], in: container)
        try configureIdentity(peer)
        try Data("peer\n".utf8).write(to: peer.appending(path: "peer.txt"))
        try runGit(["add", "peer.txt"], in: peer)
        try runGit(["commit", "-q", "-m", "peer"], in: peer)
        try runGit(["push", "-q"], in: peer)

        try runGit(["fetch", "-q"], in: primary)
        try Data("local\n".utf8).write(to: primary.appending(path: "local.txt"))
        try runGit(["add", "local.txt"], in: primary)
        try runGit(["commit", "-q", "-m", "local"], in: primary)

        let service = SidecarGitService()
        let snapshot = try #require(try await service.snapshot(workingDirectory: primary))
        #expect(snapshot.branch == "main")
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 1)
        #expect(snapshot.behind == 1)
        #expect(snapshot.remoteURL == remote.path)
    }

    @Test func commandRunnerCancelsAndTimesOutActiveProcesses() async throws {
        let runner = SidecarGitCommandRunner()
        let clock = ContinuousClock()

        let cancellationStart = clock.now
        let cancellationTask = Task {
            try await runner.submit { command in
                try command.run(
                    ["10"],
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    readOnly: false
                )
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        cancellationTask.cancel()

        do {
            _ = try await cancellationTask.value
            Issue.record("Expected the command to be cancelled.")
        } catch is CancellationError {
            // Expected.
        }
        #expect(cancellationStart.duration(to: clock.now) < .seconds(2))

        let timeoutStart = clock.now
        do {
            _ = try await runner.submit { command in
                try command.run(
                    ["10"],
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    readOnly: false,
                    timeout: 0.1
                )
            }
            Issue.record("Expected the command to time out.")
        } catch let error as SidecarGitError {
            #expect(error.message == "Git command timed out.")
        }
        #expect(timeoutStart.duration(to: clock.now) < .seconds(2))
    }

    @Test func commandRunnerTimeoutTerminatesDescendants() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appending(path: "child.pid")
        let runner = SidecarGitCommandRunner()

        do {
            _ = try await runner.submit { command in
                try command.run(
                    [
                        "-c",
                        "sleep 10 & echo $! > \"$1\"; wait",
                        "sidecar-timeout",
                        pidFile.path,
                    ],
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    readOnly: false,
                    timeout: 0.1
                )
            }
            Issue.record("Expected the command to time out.")
        } catch let error as SidecarGitError {
            #expect(error.message == "Git command timed out.")
        }

        let childPID = try #require(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        for _ in 0..<20 where Darwin.kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Darwin.kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func initializeRepository(_ directory: URL) throws {
        try runGit(["init", "-q", "--initial-branch=main"], in: directory)
        try configureIdentity(directory)
    }

    private func configureIdentity(_ directory: URL) throws {
        try runGit(["config", "user.name", "Ghostty Sidecar Test"], in: directory)
        try runGit(["config", "user.email", "sidecar@example.invalid"], in: directory)
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        in directory: URL,
        expectsSuccess: Bool = true
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if expectsSuccess {
            #expect(process.terminationStatus == 0)
        }
        return process.terminationStatus
    }
}

struct SidecarGitChangeTreeTests {
    @Test func snapshotNaturallyOrdersFlatChangesByFullPath() {
        let changes = [
            change("zeta.txt"),
            change("sources/file10.swift"),
            change("alpha.txt"),
            change("sources/file2.swift"),
        ]
        let snapshot = SidecarGitSnapshot(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            branch: "main",
            upstream: nil,
            ahead: 0,
            behind: 0,
            remoteURL: nil,
            insertions: 0,
            deletions: 0,
            changes: changes,
            availablePaths: []
        )

        #expect(snapshot.unstagedChanges.map(\.path) == [
            "alpha.txt",
            "sources/file2.swift",
            "sources/file10.swift",
            "zeta.txt",
        ])

        let refreshed = snapshot.replacingRemoteURL("https://example.com/repository.git")
        #expect(refreshed.remoteURL == "https://example.com/repository.git")
        #expect(refreshed.changes == snapshot.changes)
    }

    @Test func groupsDirectoriesBeforeFilesAtEveryLevel() {
        let changes = [
            change("root-z.txt"),
            change("sources/app.swift"),
            change("sources/ui/row10.swift"),
            change("assets/icon.png"),
            change("root-a.txt"),
            change("sources/ui/row2.swift"),
        ]

        #expect(rowOrder(in: SidecarGitChangeTree.rows(for: changes)) == [
            "D:assets",
            "F:assets/icon.png",
            "D:sources",
            "D:sources/ui",
            "F:sources/ui/row2.swift",
            "F:sources/ui/row10.swift",
            "F:sources/app.swift",
            "F:root-a.txt",
            "F:root-z.txt",
        ])
    }

    @Test func preservesEveryFileAndSupportsCollapsedDirectories() {
        let changes = [
            change("Sources/UI/Row.swift"),
            change("Sources/App.swift"),
            change("README.md"),
            change("Sources/UI/Pane.swift"),
        ]

        let expanded = SidecarGitChangeTree.rows(for: changes)
        #expect(changePaths(in: expanded) == [
            "Sources/UI/Pane.swift",
            "Sources/UI/Row.swift",
            "Sources/App.swift",
            "README.md",
        ])
        #expect(directoryPaths(in: expanded) == ["Sources", "Sources/UI"])
        #expect(directoryCounts(in: expanded) == ["Sources": 3, "Sources/UI": 2])

        let collapsed = SidecarGitChangeTree.rows(
            for: changes,
            collapsedDirectories: ["Sources"]
        )
        #expect(changePaths(in: collapsed) == ["README.md"])
        #expect(directoryPaths(in: collapsed) == ["Sources"])

        let nestedCollapsed = SidecarGitChangeTree.rows(
            for: changes,
            collapsedDirectories: ["Sources/UI"]
        )
        #expect(changePaths(in: nestedCollapsed) == [
            "Sources/App.swift",
            "README.md",
        ])
        #expect(directoryPaths(in: nestedCollapsed) == ["Sources", "Sources/UI"])
    }

    private func change(_ path: String) -> SidecarGitChange {
        .init(
            path: path,
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            isUntracked: false,
            isConflict: false
        )
    }

    private func changePaths(in rows: [SidecarGitChangeTreeRow]) -> [String] {
        rows.compactMap { row in
            guard case .change(let change, _) = row.content else { return nil }
            return change.path
        }
    }

    private func rowOrder(in rows: [SidecarGitChangeTreeRow]) -> [String] {
        rows.map { row in
            switch row.content {
            case .directory(let path, _, _):
                "D:\(path)"
            case .change(let change, _):
                "F:\(change.path)"
            }
        }
    }

    private func directoryPaths(in rows: [SidecarGitChangeTreeRow]) -> [String] {
        rows.compactMap { row in
            guard case .directory(let path, _, _) = row.content else { return nil }
            return path
        }
    }

    private func directoryCounts(in rows: [SidecarGitChangeTreeRow]) -> [String: Int] {
        rows.reduce(into: [:]) { counts, row in
            guard case .directory(let path, _, let count) = row.content else { return }
            counts[path] = count
        }
    }
}

struct SidecarFileServiceTests {
    @Test func listsDirectoriesFirstAndHonorsHiddenFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(
            atPath: root.appending(path: "z.txt").path,
            contents: Data()
        ))
        #expect(FileManager.default.createFile(
            atPath: root.appending(path: ".hidden").path,
            contents: Data()
        ))

        let service = SidecarFileService(prefersAcceleratedSearch: false)
        let visible = try await service.children(of: root, showsHiddenFiles: false)
        let all = try await service.children(of: root, showsHiddenFiles: true)

        #expect(visible.map(\.name) == ["Folder", "z.txt"])
        #expect(all.map(\.name).contains(".hidden"))
        #expect(visible.first?.isDirectory == true)
    }

    @Test func recursiveSearchIsCaseInsensitiveAndBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["Match-One.swift", "match-two.swift", "other.txt"] {
            #expect(FileManager.default.createFile(
                atPath: root.appending(path: name).path,
                contents: Data()
            ))
        }

        let service = SidecarFileService(prefersAcceleratedSearch: false)
        let results = await service.search(
            in: root,
            query: "MATCH",
            showsHiddenFiles: false,
            limit: 1
        )

        #expect(results.count == 1)
        #expect(results[0].name.localizedCaseInsensitiveContains("match"))
    }

    @Test func searchRanksFileNamesAheadOfPathOnlyMatches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pathMatch = root.appending(path: "service", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pathMatch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FileManager.default.createFile(
            atPath: pathMatch.appending(path: "unrelated.swift").path,
            contents: Data()
        ))
        #expect(FileManager.default.createFile(
            atPath: root.appending(path: "ServiceClient.swift").path,
            contents: Data()
        ))

        let service = SidecarFileService(prefersAcceleratedSearch: false)
        let results = await service.search(
            in: root,
            query: "service",
            showsHiddenFiles: false
        )

        let fileNameRank = try #require(results.firstIndex {
            $0.name == "ServiceClient.swift"
        })
        let pathOnlyRank = try #require(results.firstIndex {
            $0.name == "unrelated.swift"
        })
        #expect(fileNameRank < pathOnlyRank)
    }

    @Test func searchSupportsFuzzySubsequences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FileManager.default.createFile(
            atPath: root.appending(path: "SidecarFileService.swift").path,
            contents: Data()
        ))

        let service = SidecarFileService(prefersAcceleratedSearch: false)
        let results = await service.search(
            in: root,
            query: "scfsvc",
            showsHiddenFiles: false
        )

        #expect(results.first?.name == "SidecarFileService.swift")
    }
}

struct SidecarFileOperationServiceTests {
    @Test func createsAndRenamesFilesAndFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SidecarFileOperationService()
        let file = try await service.createFile(named: "draft.txt", in: root)
        let folder = try await service.createDirectory(named: "Sources", in: root)
        let renamed = try await service.rename(file, to: "final.txt")
        let caseRenamed = try await service.rename(renamed, to: "FINAL.txt")

        #expect(FileManager.default.fileExists(atPath: caseRenamed.path))
        #expect(caseRenamed.lastPathComponent == "FINAL.txt")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
}

@MainActor
struct SidecarQuickEditorTests {
    @Test func themeRefreshPreservesSyntaxColors() throws {
        let editor = SidecarCodeEditor(
            text: .constant("let value = 1"),
            fileName: "example.swift",
            backgroundColor: .black
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.string = "let value = 1"
        let storage = try #require(textView.textStorage)
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.systemPurple,
            range: NSRange(location: 0, length: 3)
        )

        coordinator.applyTheme(to: textView)

        let color = storage.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        #expect(color?.isEqual(NSColor.systemPurple) == true)
    }

    @Test func loadsTracksEditsSavesAndCloses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = root.appending(path: "example.swift")
        let symlink = root.appending(path: "example-link.swift")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let value = 1\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: file
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SidecarQuickEditorManager()
        let surfaceID = UUID()
        manager.open(symlink, on: surfaceID)

        #expect(await eventually {
            manager.document(for: surfaceID)?.state == .ready
        })
        let document = try #require(manager.document(for: surfaceID))
        #expect(document.text == "let value = 1\n")
        #expect(!document.isDirty)

        document.replaceText("let value = 2\n")
        #expect(document.isDirty)
        try await manager.save(document)

        #expect(!document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 2\n")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(permissions.intValue & 0o111 == 0o111)
        #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)

        manager.close(surfaceID: surfaceID)
        #expect(manager.document(for: surfaceID) == nil)
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
struct SidecarFilesModelTests {
    @Test func expandsAndCollapsesOnlyTheSelectedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ghostty-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FileManager.default.createFile(
            atPath: root.appending(path: "sibling.txt").path,
            contents: Data()
        ))
        #expect(FileManager.default.createFile(
            atPath: folder.appending(path: "child.txt").path,
            contents: Data()
        ))

        let model = SidecarFilesModel()
        model.setRoot(root)
        #expect(await eventually {
            model.rows.map(\.entry.name) == ["Folder", "sibling.txt"]
        })

        let folderEntry = try #require(model.rows.first?.entry)
        model.toggle(folderEntry)
        #expect(await eventually {
            model.rows.map(\.entry.name) == [
                "Folder",
                "child.txt",
                "sibling.txt",
            ]
        })

        model.toggle(folderEntry)
        #expect(model.rows.map(\.entry.name) == ["Folder", "sibling.txt"])

        // The second expansion is synchronous because its children are cached.
        model.toggle(folderEntry)
        #expect(model.rows.map(\.entry.name) == [
            "Folder",
            "child.txt",
            "sibling.txt",
        ])
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

struct SidecarProcessServiceTests {
    @Test func readsTheCurrentProcessWithoutScanningTheSystem() async {
        let service = SidecarProcessService()
        let snapshot = await service.snapshot(
            foregroundPID: Int(ProcessInfo.processInfo.processIdentifier)
        )

        #expect(snapshot.processes.first?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(snapshot.processes.first?.name.isEmpty == false)
        #expect(snapshot.resources.memoryBytes > 0)
        #expect(snapshot.resources.systemMemoryUsedBytes > 0)
        #expect(
            snapshot.resources.systemMemoryTotalBytes
                >= snapshot.resources.systemMemoryUsedBytes
        )
        #expect(snapshot.resources.threadCount > 0)
    }

    @Test func calculatesResourceRatesFromConsecutiveSamples() async {
        let service = SidecarProcessService()
        let pid = Int(ProcessInfo.processInfo.processIdentifier)

        let initial = await service.snapshot(foregroundPID: pid)
        #expect(initial.resources.cpuPercent == nil)
        #expect(initial.resources.systemCPUPercent == nil)
        #expect(initial.resources.readBytesPerSecond == nil)
        #expect(initial.resources.writeBytesPerSecond == nil)

        try? await Task.sleep(for: .milliseconds(600))
        let refreshed = await service.snapshot(foregroundPID: pid)

        #expect(refreshed.resources.cpuPercent != nil)
        #expect(refreshed.resources.systemCPUPercent != nil)
        #expect(refreshed.resources.readBytesPerSecond != nil)
        #expect(refreshed.resources.writeBytesPerSecond != nil)
    }

    @Test func skipsResourceSamplingWhenMonitoringIsCollapsed() async {
        let service = SidecarProcessService()
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        _ = await service.snapshot(foregroundPID: pid)
        try? await Task.sleep(for: .milliseconds(600))
        let sampled = await service.snapshot(foregroundPID: pid)
        #expect(sampled.resources.cpuPercent != nil)

        let snapshot = await service.snapshot(
            foregroundPID: Int(ProcessInfo.processInfo.processIdentifier),
            includeResources: false
        )

        #expect(!snapshot.processes.isEmpty)
        #expect(snapshot.resources == .empty)
        #expect(snapshot.processes.allSatisfy {
            $0.cpuPercent == nil
                && $0.memoryBytes == 0
                && $0.threadCount == 0
        })

        let resumed = await service.snapshot(foregroundPID: pid)
        #expect(resumed.resources.cpuPercent == nil)
        #expect(resumed.resources.readBytesPerSecond == nil)
        #expect(resumed.resources.writeBytesPerSecond == nil)
    }

    @Test func findsAListeningPortInTheForegroundProcessTree() async throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import socket, time
            server = socket.socket()
            server.bind(("127.0.0.1", 0))
            server.listen()
            print(server.getsockname()[1], flush=True)
            time.sleep(10)
            """,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let portData = output.fileHandleForReading.availableData
        let portString = try #require(String(bytes: portData, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(UInt16(portString))

        let service = SidecarProcessService()
        let snapshot = await service.snapshot(
            foregroundPID: Int(ProcessInfo.processInfo.processIdentifier)
        )

        #expect(snapshot.processes.contains { $0.pid == process.processIdentifier })
        #expect(snapshot.listeningPorts.contains {
            $0.pid == process.processIdentifier
                && $0.address == "127.0.0.1"
                && $0.port == port
        })
    }
}

struct SidecarResourceHistoryTests {
    @Test func retainsOnlyTheMostRecentSamples() {
        var history = SidecarResourceHistory()

        for index in 0..<50 {
            history.append(SidecarResourceSnapshot(
                cpuPercent: Double(index),
                systemCPUPercent: Double(index + 100),
                memoryBytes: UInt64(index),
                systemMemoryUsedBytes: UInt64(index + 200),
                systemMemoryTotalBytes: 1_000,
                readBytesPerSecond: 0,
                writeBytesPerSecond: 0,
                threadCount: 1
            ))
        }

        #expect(history.currentCPUPercent.count == 45)
        #expect(history.systemCPUPercent.count == 45)
        #expect(history.currentMemoryBytes.count == 45)
        #expect(history.systemMemoryUsedBytes.count == 45)
        #expect(history.currentCPUPercent.first == 5)
        #expect(history.currentCPUPercent.last == 49)
        #expect(history.systemCPUPercent.first == 105)
        #expect(history.systemCPUPercent.last == 149)
        #expect(history.currentMemoryBytes.first == 5)
        #expect(history.currentMemoryBytes.last == 49)
        #expect(history.systemMemoryUsedBytes.first == 205)
        #expect(history.systemMemoryUsedBytes.last == 249)
    }
}

struct SidecarResourceMonitorEntryTests {
    @Test @MainActor func cachesEachSurfaceIndependently() {
        let first = SidecarResourceMonitorEntry(surfaceID: UUID())
        let second = SidecarResourceMonitorEntry(surfaceID: UUID())
        let snapshot = SidecarProcessSnapshot(
            processes: [],
            listeningPorts: [],
            resources: SidecarResourceSnapshot(
                cpuPercent: 12,
                systemCPUPercent: 34,
                memoryBytes: 56,
                systemMemoryUsedBytes: 78,
                systemMemoryTotalBytes: 90,
                readBytesPerSecond: 1,
                writeBytesPerSecond: 2,
                threadCount: 3
            )
        )

        first.update(snapshot: snapshot, includesResources: true)

        #expect(first.value.snapshot == snapshot)
        #expect(first.value.history.currentCPUPercent == [12])
        #expect(first.value.hasResourceSample)
        #expect(!second.value.hasResourceSample)
        #expect(second.value.snapshot == .empty)
        #expect(second.value.history.currentCPUPercent.isEmpty)
    }

    @Test @MainActor func basicRefreshKeepsCachedResourceValues() {
        let entry = SidecarResourceMonitorEntry(surfaceID: UUID())
        let resourceSnapshot = SidecarProcessSnapshot(
            processes: [],
            listeningPorts: [],
            resources: SidecarResourceSnapshot(
                cpuPercent: 12,
                systemCPUPercent: 34,
                memoryBytes: 56,
                systemMemoryUsedBytes: 78,
                systemMemoryTotalBytes: 90,
                readBytesPerSecond: 1,
                writeBytesPerSecond: 2,
                threadCount: 3
            )
        )
        entry.update(
            snapshot: resourceSnapshot,
            includesResources: true
        )

        entry.update(snapshot: .empty, includesResources: false)

        #expect(entry.value.snapshot.resources == resourceSnapshot.resources)
        #expect(entry.value.history.currentCPUPercent == [12])
    }
}

struct SidecarStateTests {
    @Test @MainActor func panelMenuTagsRoundTripAndShowOpensSidecar() {
        for panel in SidecarPanel.allCases {
            #expect(SidecarPanel(menuTag: panel.menuTag) == panel)
        }
        #expect(SidecarPanel(menuTag: -1) == nil)

        let state = SidecarState(isVisible: false)
        state.show(.files)

        #expect(state.isVisible)
        #expect(state.selectedPanel == .files)
    }

    @Test @MainActor func visibilityActionsUseOneApplicationScopedState() {
        let state = SidecarState(isVisible: false)

        state.toggle()
        #expect(state.isVisible)

        state.hide()
        #expect(!state.isVisible)

        state.show(.info)
        #expect(state.isVisible)
        #expect(state.selectedPanel == .info)
    }

    @Test @MainActor func commandPaletteOptionsOpenCloseAndToggle() throws {
        let state = SidecarState(isVisible: false)
        let config = try TemporaryConfig("""
        keybind=cmd+shift+s=sidecar:toggle
        keybind=cmd+shift+i=sidecar:info
        keybind=cmd+shift+w=sidecar:hide
        """)
        let options = SidecarCommandOptions.make(
            state: state,
            config: config
        )

        #expect(options.map(\.title) == [
            "Toggle Sidecar",
            "Open Sidecar: Info",
            "Open Sidecar: Outline",
            "Open Sidecar: Git",
            "Open Sidecar: Files",
            "Close Sidecar",
        ])
        #expect(options.allSatisfy { $0.leadingIcon == nil })

        let info = try #require(options.first {
            $0.title == "Open Sidecar: Info"
        })
        #expect(info.symbols == ["⇧", "⌘", "I"])
        info.action()
        #expect(state.isVisible)
        #expect(state.selectedPanel == .info)

        let close = try #require(options.first {
            $0.title == "Close Sidecar"
        })
        #expect(close.symbols == ["⇧", "⌘", "W"])
        close.action()
        #expect(!state.isVisible)

        let toggle = try #require(options.first { $0.title == "Toggle Sidecar" })
        #expect(toggle.symbols == ["⇧", "⌘", "S"])
        toggle.action()
        #expect(state.isVisible)
    }

    @Test @MainActor func viewMenuExposesConfigurableBindings() throws {
        let viewMenu = NSMenu(title: "View")
        let inspector = NSMenuItem(
            title: "Terminal Inspector",
            action: nil,
            keyEquivalent: ""
        )
        viewMenu.addItem(inspector)

        SidecarMenuInstaller.install(before: inspector)

        let bindings = SidecarMenuInstaller.bindings(before: inspector)
        #expect(bindings.map(\.action) == [
            "sidecar:toggle",
            "sidecar:info",
            "sidecar:outline",
            "sidecar:git",
            "sidecar:files",
        ])
        #expect(bindings.allSatisfy { $0.item.keyEquivalent.isEmpty })
    }
}

@MainActor
struct SidecarContainerTests {
    @Test func widthSupportsOttyStyleResizeRange() {
        #expect(
            SidecarLayout.clampedWidth(120, availableWidth: 1_200)
                == SidecarLayout.minimumWidth
        )
        #expect(
            SidecarLayout.clampedWidth(500, availableWidth: 1_200)
                == 500
        )
        #expect(
            SidecarLayout.clampedWidth(600, availableWidth: 800)
                == 400
        )
    }

    @Test func dragDirectionMatchesTrailingSidecarDivider() {
        #expect(
            SidecarLayout.width(
                from: 224,
                horizontalTranslation: -150,
                availableWidth: 1_200
            ) == 374
        )
        #expect(
            SidecarLayout.width(
                from: 224,
                horizontalTranslation: 100,
                availableWidth: 1_200
            ) == SidecarLayout.minimumWidth
        )
    }

    @Test func dragWidthUsesStableWholePointUpdates() {
        #expect(
            SidecarLayout.width(
                from: 224,
                horizontalTranslation: -10.49,
                availableWidth: 1_200
            ) == 234
        )
        #expect(
            SidecarLayout.width(
                from: 224,
                horizontalTranslation: -10.5,
                availableWidth: 1_200
            ) == 235
        )
    }

    @Test func dragWidthAlignsToBackingPixelsOnRetinaDisplays() {
        #expect(
            SidecarLayout.width(
                from: 224,
                horizontalTranslation: -10.26,
                availableWidth: 1_200,
                displayScale: 2
            ) == 234.5
        )
        #expect(
            SidecarLayout.width(
                from: 224,
                horizontalTranslation: -10.24,
                availableWidth: 1_200,
                displayScale: 2
            ) == 234
        )
    }

    @Test func reservedAreaIncludesTrailingCardInset() {
        #expect(
            SidecarLayout.reservedWidth(panelWidth: 224)
                == 224 + SidecarLayout.cardInset
        )
    }

    @Test func reservedAreaContinuesTerminalThemeBehindFloatingCard() throws {
        let renderer = ImageRenderer(
            content: SidecarContainer(
                isVisible: .constant(true),
                sidecarWidth: .constant(224),
                reservedAreaColor: .red,
                reservedAreaOpacity: 0.5
            ) {
                Color.blue
            } sidecar: {
                Color.clear
            }
            .frame(width: 400, height: 200)
        )
        renderer.proposedSize = ProposedViewSize(width: 400, height: 200)
        renderer.scale = 1
        renderer.isOpaque = false

        let image = try #require(renderer.nsImage)
        let cgImage = try #require(
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        )
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let reservedPixel = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh / 2)
        )
        let color = try #require(reservedPixel.usingColorSpace(.sRGB))

        #expect(color.redComponent > 0.9)
        #expect(color.redComponent - color.greenComponent > 0.5)
        #expect(color.redComponent - color.blueComponent > 0.5)
        #expect(color.alphaComponent > 0.45)
    }
}

@MainActor
struct SidecarThemeTests {
    @Test func rendersLightDarkAndTransparentProductionChrome() throws {
        let light = SidecarTheme(
            backgroundColor: Color(nsColor: Self.color(hex: 0xF7F7F7)),
            backgroundOpacity: 1
        )
        let dark = SidecarTheme(
            backgroundColor: Color(nsColor: Self.color(hex: 0x090300)),
            backgroundOpacity: 1
        )
        let transparent = SidecarTheme(
            backgroundColor: Color(nsColor: Self.color(hex: 0x090300)),
            backgroundOpacity: 0.62
        )

        #expect(light.colorScheme == .light)
        #expect(dark.colorScheme == .dark)
        #expect(transparent.colorScheme == .dark)

        let lightPixel = try centerPixel(in: render(light))
        let darkPixel = try centerPixel(in: render(dark))
        let transparentPixel = try centerPixel(in: render(transparent))

        #expect(lightPixel.luminance > 0.75)
        #expect(darkPixel.luminance < 0.25)
        #expect(transparentPixel.luminance > darkPixel.luminance)
        #expect(transparentPixel.luminance < lightPixel.luminance)
        #expect(lightPixel.alphaComponent > 0.98)
        #expect(darkPixel.alphaComponent > 0.98)
        #expect(transparentPixel.alphaComponent > 0.98)
    }

    @Test func clampsInvalidOpacityWithoutChangingThemeSelection() {
        let light = Color(nsColor: Self.color(hex: 0xF7F7F7))

        let belowRange = SidecarTheme(
            backgroundColor: light,
            backgroundOpacity: -1
        )
        let aboveRange = SidecarTheme(
            backgroundColor: light,
            backgroundOpacity: 2
        )

        #expect(belowRange.backgroundOpacity == 0)
        #expect(aboveRange.backgroundOpacity == 1)
        #expect(belowRange.colorScheme == .light)
        #expect(aboveRange.colorScheme == .light)
    }

    private func render(_ theme: SidecarTheme) throws -> NSImage {
        let renderer = ImageRenderer(
            content: SidecarChrome(theme: theme) {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                    Text("Sidecar")
                }
                .foregroundStyle(.primary)
                .frame(width: 224, height: 144)
            }
        )
        renderer.proposedSize = ProposedViewSize(width: 240, height: 160)
        renderer.scale = 1
        renderer.isOpaque = false

        return try #require(renderer.nsImage)
    }

    private func centerPixel(in image: NSImage) throws -> NSColor {
        let cgImage = try #require(
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        )
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pixel = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        )
        return try #require(pixel.usingColorSpace(.sRGB))
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
