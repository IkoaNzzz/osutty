import Foundation

struct SidecarFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }

    func relativePath(from root: URL?) -> String {
        guard let root else { return url.path }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

struct SidecarFileRow: Identifiable, Hashable {
    let entry: SidecarFileEntry
    let depth: Int

    var id: URL { entry.id }
}

/// Performs filesystem enumeration away from the main actor.
///
/// Directory browsing is deliberately one level at a time. Recursive work is
/// reserved for search indexing, checks cancellation frequently, and feeds a
/// fixed-size relevance heap so a large repository cannot flood SwiftUI.
actor SidecarFileService {
    private let fileManager = FileManager.default
    private let prefersAcceleratedSearch: Bool
    private var searchIndexes: [SearchIndexKey: SearchIndex] = [:]
    private var ripgrepExecutable: URL?
    private var didResolveRipgrepExecutable = false

    private static let searchIndexLifetime: TimeInterval = 10
    private static let maximumSearchIndexCount = 4
    private static let maximumRipgrepCandidateCount = 200_000
    private static let maximumSpotlightCandidateCount = 5_000

    init(prefersAcceleratedSearch: Bool = true) {
        self.prefersAcceleratedSearch = prefersAcceleratedSearch
    }

    func children(of directory: URL, showsHiddenFiles: Bool) throws -> [SidecarFileEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = showsHiddenFiles
            ? []
            : [.skipsHiddenFiles]

        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: options
        )
        .compactMap { url in
            guard !Task.isCancelled else { return nil }

            let values = try? url.resourceValues(forKeys: keys)
            let hidden = values?.isHidden == true || url.lastPathComponent.hasPrefix(".")
            guard showsHiddenFiles || !hidden else { return nil }

            return SidecarFileEntry(
                url: url.standardizedFileURL,
                isDirectory: values?.isDirectory == true,
                isSymbolicLink: values?.isSymbolicLink == true
            )
        }
        .sorted(by: Self.entryOrder)
    }

    func search(
        in root: URL,
        query: String,
        showsHiddenFiles: Bool,
        limit: Int = 100
    ) -> [SidecarFileEntry] {
        let queryParts = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !queryParts.isEmpty, limit > 0 else { return [] }

        let key = SearchIndexKey(
            root: root.standardizedFileURL,
            showsHiddenFiles: showsHiddenFiles
        )
        let indexedEntries: [SearchIndexedEntry]
        if let cached = searchIndexes[key],
           Date().timeIntervalSince(cached.createdAt) < Self.searchIndexLifetime {
            indexedEntries = cached.entries
        } else if prefersAcceleratedSearch,
                  let ripgrepEntries = ripgrepSearch(
                      for: queryParts,
                      in: key
                  ) {
            indexedEntries = ripgrepEntries
        } else if prefersAcceleratedSearch,
                  let spotlightEntries = spotlightSearch(
                      for: queryParts,
                      in: key
                  ) {
            indexedEntries = spotlightEntries
        } else {
            let index = buildSearchIndex(for: key)
            guard !Task.isCancelled else { return [] }
            searchIndexes[key] = index
            trimSearchIndexes()
            indexedEntries = index.entries
        }

        var bestMatches = SearchCandidateHeap(limit: limit)
        for indexedEntry in indexedEntries {
            guard !Task.isCancelled else { return [] }
            guard let score = indexedEntry.score(for: queryParts) else { continue }
            bestMatches.insert(.init(indexedEntry: indexedEntry, score: score))
        }

        let resultKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        return bestMatches.sortedEntries().map { candidate in
            let indexedEntry = candidate.indexedEntry
            let values = try? indexedEntry.url.resourceValues(forKeys: resultKeys)
            return SidecarFileEntry(
                url: indexedEntry.url,
                isDirectory: values?.isDirectory == true,
                isSymbolicLink: values?.isSymbolicLink == true
            )
        }
    }

    func invalidateSearchIndex(in root: URL? = nil) {
        guard let root else {
            searchIndexes.removeAll(keepingCapacity: true)
            return
        }

        let standardizedRoot = root.standardizedFileURL
        searchIndexes = searchIndexes.filter { $0.key.root != standardizedRoot }
    }

    private func buildSearchIndex(for key: SearchIndexKey) -> SearchIndex {
        let root = key.root

        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsPackageDescendants,
        ]
        if !key.showsHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: options
        ) else {
            return .init(entries: [], createdAt: Date())
        }

        let rootPath = root.path
        var result: [SearchIndexedEntry] = []
        result.reserveCapacity(4_096)
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { break }

            let relativePath = Self.relativePath(
                of: url.path,
                from: rootPath
            )
            result.append(.init(
                url: url,
                relativePath: relativePath,
                foldedName: url.lastPathComponent.lowercased(),
                foldedPath: relativePath.lowercased()
            ))
        }

        return .init(entries: result, createdAt: Date())
    }

    /// `rg --files` uses ripgrep's parallel, ignore-aware walker. It reduces a
    /// large development tree to source-controlled and non-ignored paths before
    /// our fuzzy scorer runs, which is much faster than stat-ing every build
    /// artifact. A bundled executable is preferred, with standard install
    /// locations supported for development builds.
    private func ripgrepSearch(
        for queryParts: [String],
        in key: SearchIndexKey
    ) -> [SearchIndexedEntry]? {
        guard let executable = resolveRipgrepExecutable() else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = key.root
        process.arguments = [
            "--files",
            "--null",
            "--color=never",
            "--no-messages",
        ] + (key.showsHiddenFiles ? ["--hidden"] : [])
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            ripgrepExecutable = nil
            return nil
        }

        guard let data = readProcessOutput(
            process,
            output: output,
            maximumEntryCount: Self.maximumRipgrepCandidateCount,
            successfulTerminationStatuses: [0, 1]
        ) else {
            return Task.isCancelled ? [] : nil
        }

        var entries: [SearchIndexedEntry] = []
        var seenDirectories: Set<String> = []
        for rawPath in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard !Task.isCancelled,
                  let relativePath = String(data: rawPath, encoding: .utf8) else {
                continue
            }

            let fileURL = key.root.appending(path: relativePath)
            let fileEntry = SearchIndexedEntry(
                url: fileURL,
                relativePath: relativePath,
                foldedName: fileURL.lastPathComponent.lowercased(),
                foldedPath: relativePath.lowercased()
            )
            if fileEntry.score(for: queryParts) != nil {
                entries.append(fileEntry)
            }

            var parent = (relativePath as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                if seenDirectories.insert(parent).inserted {
                    let directoryURL = key.root.appending(path: parent)
                    let directoryEntry = SearchIndexedEntry(
                        url: directoryURL,
                        relativePath: parent,
                        foldedName: directoryURL.lastPathComponent.lowercased(),
                        foldedPath: parent.lowercased()
                    )
                    if directoryEntry.score(for: queryParts) != nil {
                        entries.append(directoryEntry)
                    }
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return entries
    }

    private func resolveRipgrepExecutable() -> URL? {
        if didResolveRipgrepExecutable { return ripgrepExecutable }
        didResolveRipgrepExecutable = true

        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "rg"),
            home.appending(path: ".cargo/bin/rg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            URL(fileURLWithPath: "/usr/local/bin/rg"),
            URL(fileURLWithPath: "/opt/local/bin/rg"),
            URL(fileURLWithPath: "/usr/bin/rg"),
        ]

        ripgrepExecutable = candidates.compactMap { $0 }.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
        return ripgrepExecutable
    }

    /// Spotlight narrows the first search in indexed local folders without
    /// walking generated trees such as DerivedData or node_modules in-process.
    /// The regular enumerator remains the fallback for volumes where mdfind is
    /// unavailable. Results are still ranked by our matcher for deterministic
    /// filename-first ordering.
    private func spotlightSearch(
        for queryParts: [String],
        in key: SearchIndexKey
    ) -> [SearchIndexedEntry]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-0",
            "-onlyin",
            key.root.path,
            Self.spotlightPredicate(for: queryParts),
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        guard let data = readProcessOutput(
            process,
            output: output,
            maximumEntryCount: Self.maximumSpotlightCandidateCount
        ) else {
            return Task.isCancelled ? [] : nil
        }

        let rootPath = key.root.path
        var entries: [SearchIndexedEntry] = []
        entries.reserveCapacity(min(
            data.reduce(into: 0) { count, byte in
                if byte == 0 { count += 1 }
            },
            Self.maximumSpotlightCandidateCount
        ))
        for rawPath in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard entries.count < Self.maximumSpotlightCandidateCount,
                  let path = String(data: rawPath, encoding: .utf8),
                  path.hasPrefix(rootPath + "/") else {
                continue
            }

            let relativePath = Self.relativePath(of: path, from: rootPath)
            if !key.showsHiddenFiles,
               relativePath.split(separator: "/").contains(where: {
                   $0.hasPrefix(".")
               }) {
                continue
            }

            let url = URL(fileURLWithPath: path)
            entries.append(.init(
                url: url,
                relativePath: relativePath,
                foldedName: url.lastPathComponent.lowercased(),
                foldedPath: relativePath.lowercased()
            ))
        }
        return entries
    }

    private func readProcessOutput(
        _ process: Process,
        output: Pipe,
        maximumEntryCount: Int,
        successfulTerminationStatuses: Set<Int32> = [0]
    ) -> Data? {
        var data = Data()
        var entryCount = 0
        var stoppedEarly = false
        var readFailed = false
        while !Task.isCancelled {
            let chunk: Data
            do {
                guard let nextChunk = try output.fileHandleForReading.read(
                    upToCount: 64 * 1_024
                ), !nextChunk.isEmpty else {
                    break
                }
                chunk = nextChunk
            } catch {
                readFailed = true
                break
            }

            data.append(chunk)
            entryCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0 { count += 1 }
            }
            if entryCount >= maximumEntryCount {
                process.terminate()
                stoppedEarly = true
                break
            }
        }

        if Task.isCancelled || readFailed, process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        guard !Task.isCancelled, !readFailed else { return nil }
        guard stoppedEarly || successfulTerminationStatuses.contains(
            process.terminationStatus
        ) else {
            return nil
        }
        return data
    }

    private static func spotlightPredicate(for queryParts: [String]) -> String {
        queryParts.map { part in
            let pattern = "*" + part.unicodeScalars.map(String.init).joined(separator: "*") + "*"
            let escaped = pattern
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "(kMDItemFSName == \"\(escaped)\"cd || "
                + "kMDItemPath == \"\(escaped)\"cd)"
        }
        .joined(separator: " && ")
    }

    private func trimSearchIndexes() {
        while searchIndexes.count > Self.maximumSearchIndexCount,
              let oldest = searchIndexes.min(by: {
                  $0.value.createdAt < $1.value.createdAt
              })?.key {
            searchIndexes[oldest] = nil
        }
    }

    private static func relativePath(of path: String, from rootPath: String) -> String {
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func entryOrder(_ lhs: SidecarFileEntry, _ rhs: SidecarFileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct SearchIndexKey: Hashable {
    let root: URL
    let showsHiddenFiles: Bool
}

private struct SearchIndex {
    let entries: [SearchIndexedEntry]
    let createdAt: Date
}

private struct SearchIndexedEntry {
    let url: URL
    let relativePath: String
    let foldedName: String
    let foldedPath: String

    func score(for queryParts: [String]) -> Int? {
        var total = 0
        for part in queryParts {
            guard let partScore = score(for: part) else { return nil }
            total += partScore
        }
        return total
    }

    private func score(for query: String) -> Int? {
        if foldedName == query { return 0 }
        if foldedName.hasPrefix(query) {
            return 25 + min(foldedName.count - query.count, 40)
        }
        if let range = foldedName.range(of: query) {
            return 100 + foldedName.distance(from: foldedName.startIndex, to: range.lowerBound)
        }
        if let range = foldedPath.range(of: query) {
            return 300 + foldedPath.distance(from: foldedPath.startIndex, to: range.lowerBound)
        }
        if let fuzzyScore = Self.fuzzySubsequenceScore(query, in: foldedName) {
            return 600 + fuzzyScore
        }
        if let fuzzyScore = Self.fuzzySubsequenceScore(query, in: foldedPath) {
            return 900 + fuzzyScore
        }
        return nil
    }

    private static func fuzzySubsequenceScore(_ query: String, in candidate: String) -> Int? {
        var queryIndex = query.unicodeScalars.startIndex
        var previousMatchOffset: Int?
        var offset = 0
        var gapPenalty = 0

        for scalar in candidate.unicodeScalars {
            guard queryIndex != query.unicodeScalars.endIndex else { break }
            if scalar == query.unicodeScalars[queryIndex] {
                if let previousMatchOffset {
                    gapPenalty += max(0, offset - previousMatchOffset - 1)
                } else {
                    gapPenalty += offset
                }
                previousMatchOffset = offset
                query.unicodeScalars.formIndex(after: &queryIndex)
            }
            offset += 1
        }

        guard queryIndex == query.unicodeScalars.endIndex else { return nil }
        return gapPenalty
    }
}

private struct SearchCandidate {
    let indexedEntry: SearchIndexedEntry
    let score: Int

    static func isBetter(_ lhs: Self, than rhs: Self) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return lhs.indexedEntry.relativePath.localizedStandardCompare(
            rhs.indexedEntry.relativePath
        ) == .orderedAscending
    }

    static func isWorse(_ lhs: Self, than rhs: Self) -> Bool {
        isBetter(rhs, than: lhs)
    }
}

/// A fixed-size max heap. Its root is the worst retained match, so considering
/// an additional indexed path is O(log limit) and only the final small result
/// set needs sorting.
private struct SearchCandidateHeap {
    let limit: Int
    private var storage: [SearchCandidate] = []

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(limit)
    }

    mutating func insert(_ candidate: SearchCandidate) {
        if storage.count < limit {
            storage.append(candidate)
            siftUp(from: storage.count - 1)
            return
        }

        guard let worst = storage.first,
              SearchCandidate.isBetter(candidate, than: worst) else {
            return
        }
        storage[0] = candidate
        siftDown(from: 0)
    }

    func sortedEntries() -> [SearchCandidate] {
        storage.sorted { SearchCandidate.isBetter($0, than: $1) }
    }

    private mutating func siftUp(from startIndex: Int) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard SearchCandidate.isWorse(storage[child], than: storage[parent]) else {
                return
            }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from startIndex: Int) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { return }
            let right = left + 1
            var worseChild = left
            if right < storage.count,
               SearchCandidate.isWorse(storage[right], than: storage[left]) {
                worseChild = right
            }
            guard SearchCandidate.isWorse(storage[worseChild], than: storage[parent]) else {
                return
            }
            storage.swapAt(parent, worseChild)
            parent = worseChild
        }
    }
}
