import AppKit
import SwiftUI

struct SidecarGitView: View {
    @ObservedObject var model: SidecarGitModel
    @ObservedObject var surface: SidecarSurfaceContext
    @StateObject private var commitWindow = SidecarCommitWindowController()
    @State private var lifecycleID = UUID()

    private var workingDirectory: URL? {
        guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true)
    }

    var body: some View {
        Group {
            if model.isLoading, model.snapshot == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = model.snapshot {
                repositoryView(snapshot)
            } else if let error = model.errorMessage {
                compactMessage(error, color: .red)
            } else {
                compactMessage("Not a Git repository")
            }
        }
        .task(id: workingDirectory) {
            guard let workingDirectory else { return }
            model.setWorkingDirectory(workingDirectory)

            var unchangedRefreshes = 0
            while !Task.isCancelled {
                let changed = await model.refresh()
                unchangedRefreshes = changed
                    ? 0
                    : min(unchangedRefreshes + 1, 3)
                let delay = switch unchangedRefreshes {
                case 0: Duration.seconds(3)
                case 1: Duration.seconds(5)
                default: Duration.seconds(10)
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
        .onAppear {
            model.activate(clientID: lifecycleID)
        }
        .onDisappear {
            model.deactivate(clientID: lifecycleID)
        }
    }

    private func compactMessage(_ message: String, color: Color = .secondary) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, SidecarMetrics.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func repositoryView(_ snapshot: SidecarGitSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                repositoryHeader(snapshot)

                Divider()
                    .opacity(0.45)
                    .padding(.top, 10)

                actionStrip(snapshot)
                    .padding(.vertical, 10)

                if model.isOperating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.operationMessage ?? "Running Git…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }

                if snapshot.changes.isEmpty {
                    Text("Working tree clean")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                } else {
                    changeList(snapshot)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, SidecarMetrics.contentPadding)
        }
    }

    private func repositoryHeader(_ snapshot: SidecarGitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(snapshot.branch)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if snapshot.insertions > 0 {
                    Text("+\(snapshot.insertions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if snapshot.deletions > 0 {
                    Text("−\(snapshot.deletions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            if let remoteURL = snapshot.remoteURL {
                Text(remoteURL)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else {
                Text(synchronizationDescription(snapshot))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func changeList(_ snapshot: SidecarGitSnapshot) -> some View {
        LazyVStack(spacing: 12) {
            if !snapshot.stagedChanges.isEmpty {
                changeSection(
                    "Staged",
                    changes: snapshot.stagedChanges,
                    snapshot: snapshot,
                    isStagedSection: true
                ) {
                    model.perform(.unstageAll, label: "Unstaging all changes…")
                } rowAction: { change in
                    model.perform(
                        .unstage(paths: change.operationPaths),
                        label: "Unstaging \(change.path)…"
                    )
                }
            }

            if !snapshot.unstagedChanges.isEmpty {
                changeSection(
                    "Unstaged",
                    changes: snapshot.unstagedChanges,
                    snapshot: snapshot,
                    isStagedSection: false
                ) {
                    model.perform(.stageAll, label: "Staging all changes…")
                } rowAction: { change in
                    model.perform(
                        .stage(paths: change.operationPaths),
                        label: "Staging \(change.path)…"
                    )
                }
            }
        }
    }

    private func changeSection(
        _ title: String,
        changes: [SidecarGitChange],
        snapshot: SidecarGitSnapshot,
        isStagedSection: Bool,
        sectionAction: @escaping () -> Void,
        rowAction: @escaping (SidecarGitChange) -> Void
    ) -> some View {
        let buttonTitle = isStagedSection ? "Unstage all" : "Stage all"

        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(title) (\(changes.count))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: sectionAction) {
                    Image(systemName: title == "Staged" ? "minus.circle" : "plus.circle")
                        .font(.system(size: 11))
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isOperating)
                    .help(buttonTitle)
            }
            .frame(height: 22)

            ForEach(changes) { change in
                SidecarGitChangeRow(
                    change: change,
                    isStaged: isStagedSection,
                    stageHelp: change.isConflict
                        ? "Resolve this conflict outside the Sidecar."
                        : (isStagedSection ? "Unstage File" : "Stage File"),
                    openEnabled: snapshot.availablePaths.contains(change.path),
                    isOperating: model.isOperating,
                    onStage: {
                        rowAction(change)
                    },
                    loadDiff: {
                        try await model.diff(
                            for: change,
                            isStaged: isStagedSection
                        )
                    },
                    onOpen: {
                        openChangedFile(change, snapshot: snapshot)
                    }
                )
            }
        }
    }

    private func actionStrip(_ snapshot: SidecarGitSnapshot) -> some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button("Commit") {
                    commitWindow.show(model: model)
                }

                Menu {
                    Button("Fetch") {
                        model.perform(.fetch, label: "Fetching…")
                    }
                    Button("Pull (Fast-forward Only)") {
                        model.perform(.pull, label: "Pulling…")
                    }
                    Button("Push") {
                        model.perform(.push, label: "Pushing…")
                    }

                    Divider()

                    Button("Merge…") {
                        promptForReference(operation: "Merge") { reference in
                            model.perform(.merge(reference: reference), label: "Merging \(reference)…")
                        }
                    }
                    Button("Rebase…") {
                        promptForReference(operation: "Rebase") { reference in
                            model.perform(.rebase(reference: reference), label: "Rebasing onto \(reference)…")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isOperating)

            let editor = SidecarEditorCatalog.gitEditors.first
            ControlGroup {
                Button {
                    open(snapshot.repositoryRoot, in: editor)
                } label: {
                    Text(editor?.name ?? "Finder")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }

                Menu {
                    if SidecarEditorCatalog.gitEditors.isEmpty {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshot.repositoryRoot])
                        }
                    } else {
                        ForEach(SidecarEditorCatalog.gitEditors) { item in
                            Button(item.name) {
                                open(snapshot.repositoryRoot, in: item)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isOperating)

            Spacer(minLength: 0)
        }
    }

    private func open(_ url: URL, in editor: SidecarEditor?) {
        guard let editor,
              let applicationURL = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: editor.bundleIdentifier
              ) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func changedFileURL(
        _ change: SidecarGitChange,
        snapshot: SidecarGitSnapshot
    ) -> URL {
        snapshot.repositoryRoot.appendingPathComponent(change.path)
    }

    private func openChangedFile(
        _ change: SidecarGitChange,
        snapshot: SidecarGitSnapshot
    ) {
        let fileURL = changedFileURL(change, snapshot: snapshot)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        open(fileURL, in: SidecarEditorCatalog.gitEditors.first)
    }

    private func synchronizationDescription(_ snapshot: SidecarGitSnapshot) -> String {
        guard snapshot.upstream != nil else { return "No upstream" }
        switch (snapshot.ahead, snapshot.behind) {
        case (0, 0): return "Up to date"
        case (let ahead, 0): return "\(ahead) ahead"
        case (0, let behind): return "\(behind) behind"
        case (let ahead, let behind): return "\(ahead) ahead, \(behind) behind"
        }
    }

    private func promptForReference(
        operation: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "\(operation) Reference"
        alert.informativeText = "Enter a branch, tag, or commit."
        alert.addButton(withTitle: operation)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: "")
        field.placeholderString = "branch or revision"
        field.frame = .init(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reference = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return }
        completion(reference)
    }
}

private struct SidecarGitChangeRow: View {
    let change: SidecarGitChange
    let isStaged: Bool
    let stageHelp: String
    let openEnabled: Bool
    let isOperating: Bool
    let onStage: () -> Void
    let loadDiff: () async throws -> String
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var isDiffPresented = false
    @State private var diffState = SidecarGitDiffState.loading
    @State private var diffTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Text(change.displayStatus)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(change.isConflict ? .red : .secondary)
                .frame(width: 14)

            Text(change.path)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)

            if isHovering || isDiffPresented {
                HStack(spacing: 1) {
                    SidecarGitRowActionButton(
                        systemImage: isStaged ? "minus" : "plus",
                        help: stageHelp,
                        accessibilityIdentifier: "sidecar-git-stage-file",
                        isDisabled: isOperating || change.isConflict,
                        action: onStage
                    )
                    SidecarGitRowActionButton(
                        systemImage: "doc.text.magnifyingglass",
                        help: "Preview Diff",
                        accessibilityIdentifier: "sidecar-git-show-diff",
                        isDisabled: isOperating,
                        action: presentDiff
                    )
                    .popover(
                        isPresented: $isDiffPresented,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .trailing
                    ) {
                        SidecarGitDiffPopover(
                            path: change.path,
                            isStaged: isStaged,
                            state: diffState
                        )
                    }
                    SidecarGitRowActionButton(
                        systemImage: "arrow.up.forward.app",
                        help: "Open File",
                        accessibilityIdentifier: "sidecar-git-open-file",
                        isDisabled: isOperating || !openEnabled,
                        action: onOpen
                    )
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, 2)
        .frame(height: SidecarMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovering || isDiffPresented ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(SidecarMetrics.contentAnimation, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(change.displayStatus) \(change.path)")
        .accessibilityIdentifier("sidecar-git-change-\(change.path)")
        .onDisappear {
            diffTask?.cancel()
        }
    }

    private func presentDiff() {
        diffTask?.cancel()
        diffState = .loading
        isDiffPresented = true

        diffTask = Task {
            do {
                let diff = try await loadDiff()
                guard !Task.isCancelled else { return }
                diffState = .content(diff)
            } catch {
                guard !Task.isCancelled else { return }
                diffState = .failure(error.localizedDescription)
            }
        }
    }
}

private struct SidecarGitRowActionButton: View {
    let systemImage: String
    let help: String
    let accessibilityIdentifier: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 19, height: 19)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidecarFocusEffectDisabled()
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovering = $0 }
        .animation(SidecarMetrics.contentAnimation, value: isHovering)
    }
}
