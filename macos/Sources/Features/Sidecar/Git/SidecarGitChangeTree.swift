import Foundation

enum SidecarGitChangePresentation: String {
    case list
    case tree
}

struct SidecarGitTreeDirectoryID: Hashable {
    let isStaged: Bool
    let path: String
}

struct SidecarGitChangeTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(path: String, name: String, changeCount: Int)
        case change(SidecarGitChange, name: String)
    }

    let content: Content
    let depth: Int

    var id: String {
        switch content {
        case .directory(let path, _, _):
            "directory:\(path)"
        case .change(let change, _):
            "change:\(change.id)"
        }
    }
}

enum SidecarGitChangeTree {
    static func rows(
        for changes: [SidecarGitChange],
        collapsedDirectories: Set<String> = []
    ) -> [SidecarGitChangeTreeRow] {
        let counts = directoryCounts(for: changes)
        let sortedChanges = changes.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        var emittedDirectories = Set<String>()
        var rows: [SidecarGitChangeTreeRow] = []

        for change in sortedChanges {
            let components = change.path.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }

            var directoryPath = ""
            var isHidden = false
            for (depth, directoryName) in components.dropLast().enumerated() {
                directoryPath = directoryPath.isEmpty
                    ? directoryName
                    : "\(directoryPath)/\(directoryName)"
                if emittedDirectories.insert(directoryPath).inserted {
                    rows.append(.init(
                        content: .directory(
                            path: directoryPath,
                            name: directoryName,
                            changeCount: counts[directoryPath, default: 0]
                        ),
                        depth: depth
                    ))
                }
                if collapsedDirectories.contains(directoryPath) {
                    isHidden = true
                    break
                }
            }

            if !isHidden {
                rows.append(.init(
                    content: .change(change, name: name),
                    depth: max(0, components.count - 1)
                ))
            }
        }
        return rows
    }

    private static func directoryCounts(
        for changes: [SidecarGitChange]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for change in changes {
            let directories = change.path.split(separator: "/").dropLast()
            var directoryPath = ""
            for directory in directories {
                directoryPath = directoryPath.isEmpty
                    ? String(directory)
                    : "\(directoryPath)/\(directory)"
                counts[directoryPath, default: 0] += 1
            }
        }
        return counts
    }
}
