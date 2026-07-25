import Foundation
import GhosttyKit

struct SidecarOutlineItem: Identifiable {
    let row: UInt32
    let command: String
    let workingDirectory: String?
    let finishedAt: Date?
    let exitCode: Int?
    let duration: TimeInterval?

    var id: String { "\(row):\(command)" }
}

struct SidecarOutlineGroup: Identifiable {
    let id: String
    let workingDirectory: String?
    let latestDate: Date?
    let items: [SidecarOutlineItem]
}

@MainActor
final class SidecarOutlineModel: ObservableObject {
    @Published private(set) var groups: [SidecarOutlineGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var jumpError: String?

    private let service = SidecarOutlineService()
    private var activeSurfaceID: UUID?
    private var snapshotGeneration: UInt64?

    @discardableResult
    func refresh(surfaceView: Ghostty.SurfaceView) async -> Bool {
        guard let surface = surfaceView.surfaceModel else { return false }
        var changed = false
        if activeSurfaceID != surfaceView.id {
            activeSurfaceID = surfaceView.id
            snapshotGeneration = nil
            if !groups.isEmpty {
                groups = []
            }
            changed = true
        }
        if groups.isEmpty, !isLoading {
            isLoading = true
        }

        let update = await service.snapshot(
            surface: surface,
            previousGeneration: snapshotGeneration
        )
        guard !Task.isCancelled else { return false }
        let coreCommands: [SidecarCoreCommand]
        switch update {
        case .unchanged:
            if isLoading {
                isLoading = false
            }
            return changed
        case .changed(let generation, let commands):
            snapshotGeneration = generation
            coreCommands = commands
            changed = true
        case .failed:
            if isLoading {
                isLoading = false
            }
            return changed
        }

        let metadata = SidecarCommandMetadataStore.shared.records(for: surfaceView)
        let refreshedGroups = buildGroups(
            commands: coreCommands,
            metadata: metadata,
            fallbackDirectory: surfaceView.pwd
        )
        groups = refreshedGroups
        if isLoading {
            isLoading = false
        }
        return changed
    }

    func jump(to item: SidecarOutlineItem, surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surfaceModel else { return }
        if ghostty_surface_scroll_to_command(surface.unsafeCValue, item.row) {
            jumpError = nil
        } else {
            jumpError = "This command has left the scrollback buffer."
        }
    }

    private func buildGroups(
        commands: [SidecarCoreCommand],
        metadata: [SidecarCommandMetadata],
        fallbackDirectory: String?
    ) -> [SidecarOutlineGroup] {
        guard !commands.isEmpty else { return [] }

        let completedCount = commands.filter(\.hasFollowingPrompt).count
        let usableMetadataCount = min(completedCount, metadata.count)
        let metadataTail = metadata.suffix(usableMetadataCount)
        var metadataIndex = metadataTail.startIndex
        let firstMetadataCommandIndex = completedCount - usableMetadataCount
        var completedIndex = 0
        var items: [SidecarOutlineItem] = []

        for command in commands {
            var record: SidecarCommandMetadata?
            if command.hasFollowingPrompt {
                if completedIndex >= firstMetadataCommandIndex,
                   metadataIndex < metadataTail.endIndex {
                    record = metadataTail[metadataIndex]
                    metadataTail.formIndex(after: &metadataIndex)
                }
                completedIndex += 1
            }

            items.append(.init(
                row: command.row,
                command: command.command,
                workingDirectory: record?.workingDirectory ?? fallbackDirectory,
                finishedAt: record?.finishedAt,
                exitCode: record?.exitCode,
                duration: record?.duration
            ))
        }

        var result: [SidecarOutlineGroup] = []
        var currentItems: [SidecarOutlineItem] = []
        var currentDirectory = items.first?.workingDirectory
        var occurrence = 0

        for item in items {
            if !currentItems.isEmpty, item.workingDirectory != currentDirectory {
                result.append(group(
                    items: currentItems,
                    directory: currentDirectory,
                    occurrence: occurrence
                ))
                occurrence += 1
                currentItems = []
                currentDirectory = item.workingDirectory
            }
            currentItems.append(item)
        }

        if !currentItems.isEmpty {
            result.append(group(
                items: currentItems,
                directory: currentDirectory,
                occurrence: occurrence
            ))
        }
        return result
    }

    private func group(
        items: [SidecarOutlineItem],
        directory: String?,
        occurrence: Int
    ) -> SidecarOutlineGroup {
        .init(
            id: "\(directory ?? ""):\(occurrence):\(items.first?.row ?? 0)",
            workingDirectory: directory,
            latestDate: items.compactMap(\.finishedAt).max(),
            items: items
        )
    }
}
