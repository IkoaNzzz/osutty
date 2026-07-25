import Foundation

@MainActor
final class SidecarFilesModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var rows: [SidecarFileRow] = []
    @Published private(set) var searchResults: [SidecarFileEntry] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedEntry: SidecarFileEntry?
    @Published var showsHiddenFiles = false
    @Published var searchQuery = ""

    private static let directoryCacheDuration: TimeInterval = 5
    private static let searchCacheDuration: TimeInterval = 15
    private static let maximumDirectoryCacheCount = 256
    private static let maximumSearchCacheCount = 16

    // Recursive searches must not serialize ordinary directory browsing behind
    // a potentially large filesystem walk.
    private let browseService = SidecarFileService()
    private let searchService = SidecarFileService()
    private var directoryCache: [DirectoryCacheKey: DirectoryCacheEntry] = [:]
    private var searchCache: [SearchCacheKey: SearchCacheEntry] = [:]
    private var expandedDirectories = Set<URL>()
    private var loadTasks: [DirectoryCacheKey: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var activeSearchKey: SearchCacheKey?
    private var followsTerminalDirectory = true

    var selection: URL? { selectedEntry?.url }

    var isLoading: Bool {
        searchQuery.isEmpty ? isBrowsing : isSearching
    }

    func setTerminalRoot(_ url: URL) {
        guard followsTerminalDirectory else { return }
        setRoot(url)
    }

    func browse(_ url: URL) {
        followsTerminalDirectory = false
        setRoot(url)
    }

    func setRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != root else {
            refreshVisibleDirectories()
            return
        }

        cancelAll()
        root = standardized
        selectedEntry = nil
        expandedDirectories.removeAll(keepingCapacity: true)
        searchResults = []
        errorMessage = nil
        rows = []
        load(directory: standardized, isRoot: true)
    }

    func reloadForVisibilityChange() {
        guard let root else { return }

        cancelAll()
        searchResults = []
        errorMessage = nil
        replaceRootRows()
        load(directory: root, isRoot: true)
        for directory in expandedDirectories {
            load(directory: directory, isRoot: false)
        }
        if !searchQuery.isEmpty {
            search()
        }
    }

    func toggle(_ entry: SidecarFileEntry) {
        guard entry.isDirectory, !entry.isSymbolicLink else { return }

        if expandedDirectories.remove(entry.url) != nil {
            removeDescendants(of: entry.url)
            return
        }

        expandedDirectories.insert(entry.url)
        replaceDescendants(of: entry.url)
        load(directory: entry.url, isRoot: false)
    }

    func isExpanded(_ entry: SidecarFileEntry) -> Bool {
        expandedDirectories.contains(entry.url)
    }

    func select(_ entry: SidecarFileEntry?) {
        selectedEntry = entry
    }

    func search() {
        searchTask?.cancel()
        searchTask = nil
        activeSearchKey = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        let key = SearchCacheKey(
            root: root,
            query: query,
            showsHiddenFiles: showsHiddenFiles
        )
        let now = Date()
        if var cached = searchCache[key],
           now.timeIntervalSince(cached.loadedAt) < Self.searchCacheDuration {
            cached.lastAccessedAt = now
            searchCache[key] = cached
            searchResults = cached.entries
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        activeSearchKey = key
        searchTask = Task { [weak self, searchService] in
            let result = await searchService.search(
                in: root,
                query: query,
                showsHiddenFiles: key.showsHiddenFiles
            )
            guard !Task.isCancelled else { return }
            self?.finishSearch(result, key: key)
        }
    }

    func cancelAll() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        searchTask?.cancel()
        searchTask = nil
        activeSearchKey = nil
        isBrowsing = false
        isSearching = false
    }

    private func refreshVisibleDirectories() {
        guard let root else { return }
        load(directory: root, isRoot: true)
        for directory in expandedDirectories {
            load(directory: directory, isRoot: false)
        }
    }

    private func load(directory: URL, isRoot: Bool) {
        let key = DirectoryCacheKey(
            directory: directory,
            showsHiddenFiles: showsHiddenFiles
        )
        guard loadTasks[key] == nil else { return }

        let now = Date()
        if var cached = directoryCache[key] {
            cached.lastAccessedAt = now
            directoryCache[key] = cached
            if isRoot {
                replaceRootRows()
            } else {
                replaceDescendants(of: directory)
            }
            if now.timeIntervalSince(cached.loadedAt)
                < Self.directoryCacheDuration {
                return
            }
        } else if isRoot {
            isBrowsing = true
        }

        loadTasks[key] = Task { [weak self, browseService] in
            do {
                let entries = try await browseService.children(
                    of: directory,
                    showsHiddenFiles: key.showsHiddenFiles
                )
                guard !Task.isCancelled else { return }
                self?.finishLoad(entries, key: key, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLoad([], key: key, error: error)
            }
        }
    }

    private func finishLoad(
        _ entries: [SidecarFileEntry],
        key: DirectoryCacheKey,
        error: Error?
    ) {
        loadTasks[key] = nil
        let now = Date()
        directoryCache[key] = .init(
            entries: entries,
            loadedAt: now,
            lastAccessedAt: now
        )
        trimDirectoryCache()

        if key.directory == root {
            if isBrowsing {
                isBrowsing = false
            }
            let message = error?.localizedDescription
            if errorMessage != message {
                errorMessage = message
            }
            replaceRootRows()
        } else if key.showsHiddenFiles == showsHiddenFiles {
            replaceDescendants(of: key.directory)
        }
    }

    private func finishSearch(
        _ entries: [SidecarFileEntry],
        key: SearchCacheKey
    ) {
        let now = Date()
        searchCache[key] = .init(
            entries: entries,
            loadedAt: now,
            lastAccessedAt: now
        )
        trimSearchCache()

        guard activeSearchKey == key else { return }
        activeSearchKey = nil
        guard root == key.root,
              showsHiddenFiles == key.showsHiddenFiles,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                == key.query else {
            isSearching = false
            return
        }
        searchResults = entries
        isSearching = false
    }

    private func replaceRootRows() {
        guard let root else {
            if !rows.isEmpty {
                rows = []
            }
            return
        }

        let updated = visibleRows(of: root, depth: 0)
        if rows != updated {
            rows = updated
        }
    }

    private func replaceDescendants(of directory: URL) {
        guard let index = rows.firstIndex(where: {
            $0.entry.url == directory
        }) else {
            return
        }

        let range = descendantRange(after: index)
        let replacement = expandedDirectories.contains(directory)
            ? visibleRows(of: directory, depth: rows[index].depth + 1)
            : []
        guard !rows[range].elementsEqual(replacement) else { return }

        var updated = rows
        updated.replaceSubrange(range, with: replacement)
        rows = updated
    }

    private func removeDescendants(of directory: URL) {
        guard let index = rows.firstIndex(where: {
            $0.entry.url == directory
        }) else {
            return
        }

        let range = descendantRange(after: index)
        guard !range.isEmpty else { return }
        var updated = rows
        updated.removeSubrange(range)
        rows = updated
    }

    private func descendantRange(after index: Int) -> Range<Int> {
        let depth = rows[index].depth
        var end = index + 1
        while end < rows.endIndex, rows[end].depth > depth {
            end += 1
        }
        return (index + 1)..<end
    }

    private func visibleRows(
        of directory: URL,
        depth: Int
    ) -> [SidecarFileRow] {
        guard let entries = cachedChildren(of: directory) else { return [] }

        var result: [SidecarFileRow] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            result.append(.init(entry: entry, depth: depth))
            if entry.isDirectory, expandedDirectories.contains(entry.url) {
                result.append(contentsOf: visibleRows(
                    of: entry.url,
                    depth: depth + 1
                ))
            }
        }
        return result
    }

    private func cachedChildren(of directory: URL) -> [SidecarFileEntry]? {
        directoryCache[.init(
            directory: directory,
            showsHiddenFiles: showsHiddenFiles
        )]?.entries
    }

    private func trimDirectoryCache() {
        while directoryCache.count > Self.maximumDirectoryCacheCount,
              let oldest = directoryCache.min(by: {
                  $0.value.lastAccessedAt < $1.value.lastAccessedAt
              })?.key {
            directoryCache[oldest] = nil
        }
    }

    private func trimSearchCache() {
        while searchCache.count > Self.maximumSearchCacheCount,
              let oldest = searchCache.min(by: {
                  $0.value.lastAccessedAt < $1.value.lastAccessedAt
              })?.key {
            searchCache[oldest] = nil
        }
    }
}

private struct DirectoryCacheKey: Hashable {
    let directory: URL
    let showsHiddenFiles: Bool

    init(directory: URL, showsHiddenFiles: Bool) {
        self.directory = directory.standardizedFileURL
        self.showsHiddenFiles = showsHiddenFiles
    }
}

private struct DirectoryCacheEntry {
    let entries: [SidecarFileEntry]
    let loadedAt: Date
    var lastAccessedAt: Date
}

private struct SearchCacheKey: Hashable {
    let root: URL
    let query: String
    let showsHiddenFiles: Bool

    init(root: URL, query: String, showsHiddenFiles: Bool) {
        self.root = root.standardizedFileURL
        self.query = query
        self.showsHiddenFiles = showsHiddenFiles
    }
}

private struct SearchCacheEntry {
    let entries: [SidecarFileEntry]
    let loadedAt: Date
    var lastAccessedAt: Date
}
