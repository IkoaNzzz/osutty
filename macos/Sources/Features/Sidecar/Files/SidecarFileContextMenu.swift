import AppKit
import SwiftUI

struct SidecarFileContextMenu: View {
    let entry: SidecarFileEntry
    let surfaceID: UUID
    @ObservedObject var model: SidecarFilesModel
    @ObservedObject var quickEditorManager: SidecarQuickEditorManager

    var body: some View {
        Group {
            if entry.isDirectory {
                Button("Open in Files Panel", action: openInFilesPanel)
            }

            Button("Open", action: open)

            if !entry.isDirectory {
                Button("Quick Look", action: openInCurrentPane)
            }

            Divider()

            Button("New File…", action: createFile)
            Button("New Folder…", action: createFolder)
            Button("Rename…", action: rename)
            Button("Move to Trash", role: .destructive, action: moveToTrash)

            Divider()

            Button("Copy Path") {
                copyToPasteboard(entry.url.path)
            }
            Button("Copy Relative Path") {
                copyToPasteboard(entry.relativePath(from: model.root))
            }
            Button("Reveal in Finder", action: revealInFinder)
        }
    }

    private func openInFilesPanel() {
        model.select(entry)
        model.searchQuery = ""
        model.browse(entry.url)
    }

    private func open() {
        model.select(entry)
        NSWorkspace.shared.open(entry.url)
    }

    private func openInCurrentPane() {
        model.select(entry)
        let url = entry.url.standardizedFileURL
        guard let currentDocument = quickEditorManager.document(for: surfaceID) else {
            quickEditorManager.open(url, on: surfaceID)
            return
        }
        guard currentDocument.url != url else { return }
        guard currentDocument.isDirty else {
            quickEditorManager.open(url, on: surfaceID)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(currentDocument.url.lastPathComponent)”?"
        alert.informativeText = "Opening another file will close the current editor."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveThenOpen(url, replacing: currentDocument)
        case .alertThirdButtonReturn:
            quickEditorManager.open(url, on: surfaceID)
        default:
            break
        }
    }

    private func saveThenOpen(
        _ url: URL,
        replacing document: SidecarQuickEditorDocument
    ) {
        Task {
            do {
                try await quickEditorManager.save(document)
                guard quickEditorManager.document(for: surfaceID) === document else {
                    return
                }
                quickEditorManager.open(url, on: surfaceID)
            } catch {
                present(error)
            }
        }
    }

    private func createFile() {
        guard let name = promptForName(
            title: "New File",
            message: "Enter a name for the new file.",
            defaultName: "untitled"
        ) else { return }
        performFileOperation {
            _ = try await Self.fileOperations.createFile(
                named: name,
                in: containingDirectory
            )
        }
    }

    private func createFolder() {
        guard let name = promptForName(
            title: "New Folder",
            message: "Enter a name for the new folder.",
            defaultName: "New Folder"
        ) else { return }
        performFileOperation {
            _ = try await Self.fileOperations.createDirectory(
                named: name,
                in: containingDirectory
            )
        }
    }

    private func rename() {
        guard let name = promptForName(
            title: "Rename",
            message: "Enter a new name for “\(entry.name)”.",
            defaultName: entry.name
        ), name != entry.name else { return }
        performFileOperation {
            _ = try await Self.fileOperations.rename(entry.url, to: name)
        }
    }

    private func performFileOperation(
        _ operation: @escaping () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
                model.refreshAfterFilesystemChange()
            } catch {
                present(error)
            }
        }
    }

    private func moveToTrash() {
        model.select(entry)
        NSWorkspace.shared.recycle([entry.url]) { _, error in
            DispatchQueue.main.async {
                if let error {
                    present(error)
                } else {
                    model.refreshAfterFilesystemChange()
                }
            }
        }
    }

    private func revealInFinder() {
        model.select(entry)
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    private var containingDirectory: URL {
        entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
    }

    private func promptForName(
        title: String,
        message: String,
        defaultName: String
    ) -> String? {
        let input = NSTextField(string: defaultName)
        input.placeholderString = "Name"
        input.frame = .init(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.accessoryView = input
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        input.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func present(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private static let fileOperations = SidecarFileOperationService()
}
