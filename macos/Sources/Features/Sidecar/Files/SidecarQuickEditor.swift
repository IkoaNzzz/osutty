import AppKit
import SwiftUI

@MainActor
final class SidecarQuickEditorManager: ObservableObject {
    @Published private var documents: [UUID: SidecarQuickEditorDocument] = [:]

    private let fileService = SidecarQuickEditorFileService()
    private var loadTasks: [UUID: Task<Void, Never>] = [:]

    func document(for surfaceID: UUID) -> SidecarQuickEditorDocument? {
        documents[surfaceID]
    }

    func open(_ url: URL, on surfaceID: UUID) {
        loadTasks[surfaceID]?.cancel()

        let document = SidecarQuickEditorDocument(url: url.standardizedFileURL)
        documents[surfaceID] = document
        loadTasks[surfaceID] = Task { [weak self, fileService] in
            do {
                let text = try await fileService.load(url: document.url)
                guard !Task.isCancelled else { return }
                self?.finishLoading(text, document: document, on: surfaceID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLoading(error, document: document, on: surfaceID)
            }
        }
    }

    func retry(_ document: SidecarQuickEditorDocument, on surfaceID: UUID) {
        open(document.url, on: surfaceID)
    }

    func save(_ document: SidecarQuickEditorDocument) async throws {
        guard !document.isSaving else {
            throw SidecarQuickEditorError.saveInProgress
        }
        let snapshot = document.text
        let revision = document.revision
        document.beginSaving()
        do {
            try await fileService.save(snapshot, to: document.url)
            document.finishSaving(revision: revision)
        } catch {
            document.failSaving()
            throw error
        }
    }

    func close(surfaceID: UUID) {
        loadTasks[surfaceID]?.cancel()
        loadTasks[surfaceID] = nil
        documents[surfaceID] = nil
    }

    private func finishLoading(
        _ text: String,
        document: SidecarQuickEditorDocument,
        on surfaceID: UUID
    ) {
        loadTasks[surfaceID] = nil
        guard documents[surfaceID] === document else { return }
        document.finishLoading(text)
    }

    private func finishLoading(
        _ error: Error,
        document: SidecarQuickEditorDocument,
        on surfaceID: UUID
    ) {
        loadTasks[surfaceID] = nil
        guard documents[surfaceID] === document else { return }
        document.finishLoading(error: error.localizedDescription)
    }
}

@MainActor
final class SidecarQuickEditorDocument: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let url: URL
    @Published private(set) var state: State = .loading
    @Published private(set) var text = ""
    @Published private(set) var revision = 0
    @Published private(set) var savedRevision = 0
    @Published private(set) var isSaving = false

    var isDirty: Bool { revision != savedRevision }

    init(url: URL) {
        self.url = url
    }

    func replaceText(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        revision &+= 1
    }

    func finishLoading(_ text: String) {
        self.text = text
        revision = 0
        savedRevision = 0
        state = .ready
    }

    func finishLoading(error: String) {
        state = .failed(error)
    }

    func beginSaving() {
        isSaving = true
    }

    func finishSaving(revision: Int) {
        savedRevision = revision
        isSaving = false
    }

    func failSaving() {
        isSaving = false
    }
}

private actor SidecarQuickEditorFileService {
    private static let maximumFileSize = 16 * 1_024 * 1_024
    private let fileManager = FileManager.default

    func load(url: URL) throws -> String {
        let source = url.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true else {
            throw SidecarQuickEditorError.notARegularFile
        }
        if let fileSize = values.fileSize, fileSize > Self.maximumFileSize {
            throw SidecarQuickEditorError.fileTooLarge
        }

        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard !data.prefix(8_192).contains(0) else {
            throw SidecarQuickEditorError.binaryFile
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SidecarQuickEditorError.unsupportedEncoding
        }
        return text
    }

    func save(_ text: String, to url: URL) throws {
        let destination = url.resolvingSymlinksInPath()
        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: ".osutty-save-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        try Data(text.utf8).write(to: temporary)
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: temporary
        )
    }
}

private enum SidecarQuickEditorError: LocalizedError {
    case notARegularFile
    case fileTooLarge
    case binaryFile
    case unsupportedEncoding
    case saveInProgress

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            "Quick Editor can only open regular files."
        case .fileTooLarge:
            "This file is larger than the 16 MB Quick Editor limit."
        case .binaryFile:
            "This appears to be a binary file."
        case .unsupportedEncoding:
            "Quick Editor currently supports UTF-8 text files."
        case .saveInProgress:
            "This file is already being saved."
        }
    }
}

struct SidecarQuickEditorPane: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var document: SidecarQuickEditorDocument
    let manager: SidecarQuickEditorManager
    let surfaceView: Ghostty.SurfaceView

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.35)

            switch document.state {
            case .loading:
                ProgressView("Opening \(document.url.lastPathComponent)…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                SidecarCodeEditor(
                    text: .init(
                        get: { document.text },
                        set: { document.replaceText($0) }
                    ),
                    fileExtension: document.url.pathExtension,
                    backgroundColor: NSColor(ghostty.config.backgroundColor)
                )
            case .failed(let message):
                SidecarQuickEditorFailureView(
                    fileName: document.url.lastPathComponent,
                    message: message,
                    retry: {
                        manager.retry(document, on: surfaceView.id)
                    }
                )
            }
        }
        .background(ghostty.config.backgroundColor)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Editor, \(document.url.lastPathComponent)")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(document.url.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(document.url.deletingLastPathComponent().path)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Button(saveTitle) {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!document.isDirty || document.isSaving || document.state != .ready)

            Button("Close") {
                close()
            }
            .disabled(document.isSaving)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var saveTitle: String {
        if document.isSaving { return "Saving…" }
        return document.isDirty ? "Save" : "Saved"
    }

    private func save() {
        Task {
            do {
                try await manager.save(document)
            } catch {
                present(error)
            }
        }
    }

    private func close() {
        guard !document.isSaving else { return }
        guard document.isDirty else {
            finishClosing()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                do {
                    try await manager.save(document)
                    finishClosing()
                } catch {
                    present(error)
                }
            }
        case .alertThirdButtonReturn:
            finishClosing()
        default:
            break
        }
    }

    private func finishClosing() {
        manager.close(surfaceID: surfaceView.id)
        Task { @MainActor in
            await Task.yield()
            Ghostty.moveFocus(to: surfaceView)
        }
    }

    private func present(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

private struct SidecarQuickEditorFailureView: View {
    let fileName: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Unable to Open \(fileName)")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
