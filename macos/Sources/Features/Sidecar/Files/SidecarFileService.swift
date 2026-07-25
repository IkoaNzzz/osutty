import Foundation

struct SidecarFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct SidecarFileRow: Identifiable, Hashable {
    let entry: SidecarFileEntry
    let depth: Int

    var id: URL { entry.id }
}

/// Performs filesystem enumeration away from the main actor.
///
/// Directory browsing is deliberately one level at a time. Recursive work is
/// reserved for an explicit search, checks cancellation frequently, and is
/// capped so a large repository cannot flood SwiftUI with rows.
actor SidecarFileService {
    private let fileManager = FileManager.default

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
                url: url,
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
        limit: Int = 500
    ) -> [SidecarFileEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
        ]
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsPackageDescendants,
        ]
        if !showsHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var result: [SidecarFileEntry] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return [] }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let hidden = values?.isHidden == true || url.lastPathComponent.hasPrefix(".")
            if !showsHiddenFiles, hidden {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard url.lastPathComponent.localizedCaseInsensitiveContains(normalizedQuery) else {
                continue
            }

            result.append(SidecarFileEntry(
                url: url,
                isDirectory: values?.isDirectory == true,
                isSymbolicLink: values?.isSymbolicLink == true
            ))
            if result.count == limit { break }
        }

        return result.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private static func entryOrder(_ lhs: SidecarFileEntry, _ rhs: SidecarFileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
