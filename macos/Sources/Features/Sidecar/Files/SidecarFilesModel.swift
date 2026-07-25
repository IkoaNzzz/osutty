import Foundation

@MainActor
final class SidecarFilesModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var rows: [SidecarFileRow] = []
    @Published private(set) var searchResults: [SidecarFileEntry] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published var showsHiddenFiles = false
    @Published var searchQuery = ""
    @Published var selection: URL?

    // Recursive searches must not serialize ordinary directory browsing behind
    // a potentially large filesystem walk.
    private let browseService = SidecarFileService()
    private let searchService = SidecarFileService()
    private var children: [URL: [SidecarFileEntry]] = [:]
    private var expandedDirectories = Set<URL>()
    private var loadTasks: [URL: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?

    var isLoading: Bool {
        searchQuery.isEmpty ? isBrowsing : isSearching
    }

    func setRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != root else { return }

        cancelAll()
        root = standardized
        selection = nil
        children.removeAll(keepingCapacity: true)
        expandedDirectories.removeAll(keepingCapacity: true)
        searchResults = []
        errorMessage = nil
        rows = []
        load(directory: standardized, isRoot: true)
    }

    func reload() {
        guard let root else { return }
        let expanded = expandedDirectories
        cancelAll()
        children.removeAll(keepingCapacity: true)
        expandedDirectories = expanded
        rows = []
        load(directory: root, isRoot: true)
        for directory in expanded {
            load(directory: directory, isRoot: false)
        }
        if !searchQuery.isEmpty {
            search()
        }
    }

    func toggle(_ entry: SidecarFileEntry) {
        guard entry.isDirectory, !entry.isSymbolicLink else { return }

        if expandedDirectories.remove(entry.url) != nil {
            rebuildRows()
            return
        }

        expandedDirectories.insert(entry.url)
        rebuildRows()
        if children[entry.url] == nil {
            load(directory: entry.url, isRoot: false)
        }
    }

    func isExpanded(_ entry: SidecarFileEntry) -> Bool {
        expandedDirectories.contains(entry.url)
    }

    func search() {
        searchTask?.cancel()
        searchTask = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        let showsHiddenFiles = showsHiddenFiles
        searchTask = Task { [weak self, searchService] in
            let result = await searchService.search(
                in: root,
                query: query,
                showsHiddenFiles: showsHiddenFiles
            )
            guard !Task.isCancelled else { return }
            self?.searchResults = result
            self?.isSearching = false
        }
    }

    func cancelAll() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        searchTask?.cancel()
        searchTask = nil
        isBrowsing = false
        isSearching = false
    }

    private func load(directory: URL, isRoot: Bool) {
        guard loadTasks[directory] == nil else { return }

        if isRoot {
            isBrowsing = true
        }
        let showsHiddenFiles = showsHiddenFiles
        loadTasks[directory] = Task { [weak self, browseService] in
            do {
                let entries = try await browseService.children(
                    of: directory,
                    showsHiddenFiles: showsHiddenFiles
                )
                guard !Task.isCancelled else { return }
                self?.finishLoad(entries, directory: directory, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLoad([], directory: directory, error: error)
            }
        }
    }

    private func finishLoad(
        _ entries: [SidecarFileEntry],
        directory: URL,
        error: Error?
    ) {
        loadTasks[directory] = nil
        children[directory] = entries
        if directory == root {
            isBrowsing = false
            errorMessage = error?.localizedDescription
        }
        rebuildRows()
    }

    private func rebuildRows() {
        guard let root else {
            rows = []
            return
        }

        var result: [SidecarFileRow] = []
        appendChildren(of: root, depth: 0, to: &result)
        rows = result
    }

    private func appendChildren(
        of directory: URL,
        depth: Int,
        to result: inout [SidecarFileRow]
    ) {
        guard let entries = children[directory] else { return }
        for entry in entries {
            result.append(.init(entry: entry, depth: depth))
            if entry.isDirectory, expandedDirectories.contains(entry.url) {
                appendChildren(of: entry.url, depth: depth + 1, to: &result)
            }
        }
    }
}
