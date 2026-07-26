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

enum SidecarGitChangeOrdering {
    static func sorted(_ changes: [SidecarGitChange]) -> [SidecarGitChange] {
        changes.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return naturallyPrecedes(lhs.path, rhs.path)
            }
            return lhs.id < rhs.id
        }
    }

    static func naturallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            lhs < rhs
        }
    }
}

enum SidecarGitChangeTree {
    static func rows(
        for changes: [SidecarGitChange],
        collapsedDirectories: Set<String> = []
    ) -> [SidecarGitChangeTreeRow] {
        let root = DirectoryNode()
        for change in changes {
            root.insert(change)
        }

        var rows: [SidecarGitChangeTreeRow] = []
        rows.reserveCapacity(changes.count)
        appendRows(
            from: root,
            parentPath: "",
            depth: 0,
            collapsedDirectories: collapsedDirectories,
            to: &rows
        )
        return rows
    }

    private static func appendRows(
        from node: DirectoryNode,
        parentPath: String,
        depth: Int,
        collapsedDirectories: Set<String>,
        to rows: inout [SidecarGitChangeTreeRow]
    ) {
        let directories = node.directories.sorted { lhs, rhs in
            SidecarGitChangeOrdering.naturallyPrecedes(lhs.key, rhs.key)
        }
        for (name, directory) in directories {
            let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            rows.append(.init(
                content: .directory(
                    path: path,
                    name: name,
                    changeCount: directory.changeCount
                ),
                depth: depth
            ))
            if !collapsedDirectories.contains(path) {
                appendRows(
                    from: directory,
                    parentPath: path,
                    depth: depth + 1,
                    collapsedDirectories: collapsedDirectories,
                    to: &rows
                )
            }
        }

        for item in node.changes.sorted(by: { lhs, rhs in
            if lhs.name != rhs.name {
                return SidecarGitChangeOrdering.naturallyPrecedes(lhs.name, rhs.name)
            }
            return lhs.change.id < rhs.change.id
        }) {
            rows.append(.init(
                content: .change(item.change, name: item.name),
                depth: depth
            ))
        }
    }

    private final class DirectoryNode {
        typealias ChangeItem = (name: String, change: SidecarGitChange)

        var changeCount = 0
        var directories: [String: DirectoryNode] = [:]
        var changes: [ChangeItem] = []

        func insert(_ change: SidecarGitChange) {
            insert(change, components: change.path.split(separator: "/")[...])
        }

        private func insert(
            _ change: SidecarGitChange,
            components: ArraySlice<Substring>
        ) {
            guard let component = components.first else { return }
            changeCount += 1

            let name = String(component)
            let remainingComponents = components.dropFirst()
            guard !remainingComponents.isEmpty else {
                changes.append((name: name, change: change))
                return
            }

            directory(named: name).insert(
                change,
                components: remainingComponents
            )
        }

        private func directory(named name: String) -> DirectoryNode {
            if let directory = directories[name] {
                return directory
            }

            let directory = DirectoryNode()
            directories[name] = directory
            return directory
        }
    }
}
