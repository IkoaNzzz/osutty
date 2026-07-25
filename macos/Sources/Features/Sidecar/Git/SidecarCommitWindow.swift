import AppKit
import SwiftUI

@MainActor
final class SidecarCommitWindowController: ObservableObject {
    private var windowController: NSWindowController?

    func show(model: SidecarGitModel) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SidecarCommitView(model: model) { [weak self] in
            self?.windowController?.close()
            self?.windowController = nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Commit Changes"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(.init(width: 520, height: 500))
        window.minSize = .init(width: 420, height: 360)
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
    }
}

private struct SidecarCommitView: View {
    @ObservedObject var model: SidecarGitModel
    let close: () -> Void

    @State private var message = ""
    @State private var lifecycleID = UUID()

    private var snapshot: SidecarGitSnapshot? { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit Changes")
                .font(.title2.weight(.semibold))

            Text(snapshot?.repositoryRoot.path ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack {
                Button("Stage All") {
                    model.perform(.stageAll, label: "Staging all changes…")
                }
                Button("Unstage All") {
                    model.perform(.unstageAll, label: "Unstaging all changes…")
                }
                Spacer()
                Text("\(snapshot?.stagedChanges.count ?? 0) staged")
                    .foregroundStyle(.secondary)
            }

            List {
                if let snapshot {
                    Section("Staged") {
                        ForEach(snapshot.stagedChanges) { change in
                            CommitFileRow(change: change, isStaged: true) {
                                model.perform(
                                    .unstage(paths: change.operationPaths),
                                    label: "Unstaging \(change.path)…"
                                )
                            }
                        }
                    }

                    Section("Unstaged") {
                        ForEach(snapshot.unstagedChanges) { change in
                            CommitFileRow(change: change, isStaged: false) {
                                model.perform(
                                    .stage(paths: change.operationPaths),
                                    label: "Staging \(change.path)…"
                                )
                            }
                        }
                    }
                }
            }
            .overlay {
                if snapshot?.changes.isEmpty != false {
                    Text("Working tree clean")
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 70, maxHeight: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor))
                }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                if model.isOperating {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.operationMessage ?? "Running Git…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Commit") {
                    model.perform(.commit(message: message), label: "Committing…")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.isOperating
                        || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || snapshot?.stagedChanges.isEmpty != false
                )
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            model.activate(clientID: lifecycleID)
        }
        .onDisappear {
            model.deactivate(clientID: lifecycleID)
        }
    }
}

private struct CommitFileRow: View {
    let change: SidecarGitChange
    let isStaged: Bool
    let toggle: () -> Void

    var body: some View {
        Toggle(isOn: .init(
            get: { isStaged },
            set: { _ in toggle() }
        )) {
            HStack {
                Text(change.displayStatus)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(change.isConflict ? .red : .secondary)
                    .frame(width: 14)
                Text(change.path)
                    .lineLimit(1)
            }
        }
        .disabled(change.isConflict)
    }
}
