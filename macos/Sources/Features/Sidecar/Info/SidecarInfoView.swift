import AppKit
import SwiftUI

struct SidecarInfoView: View {
    @ObservedObject var surface: SidecarSurfaceContext

    @State private var processSnapshot = SidecarProcessSnapshot.empty

    private var workingDirectory: URL? {
        guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SidecarMetrics.sectionSpacing) {
                workspaceSection
                SidecarProcessSection(snapshot: processSnapshot)
                portsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, SidecarMetrics.contentPadding)
        }
        .task(id: surface.id) {
            await refreshProcessLoop()
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        SidecarSection("Working Directory") {
            if let workingDirectory {
                Text(workingDirectory.abbreviatingWithTilde)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                SidecarActionButton(title: "Copy Path", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(workingDirectory.path, forType: .string)
                }

                SidecarActionButton(title: "Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workingDirectory])
                }

                ForEach(SidecarEditorCatalog.infoEditors) { editor in
                    SidecarActionButton(
                        title: "Open in \(editor.name)",
                        systemImage: "arrow.up.forward.app"
                    ) {
                        open(workingDirectory, in: editor)
                    }
                }
            } else {
                Text("Waiting for shell integration to report a directory.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var portsSection: some View {
        SidecarSection("Ports") {
            if processSnapshot.listeningPorts.isEmpty {
                Text("No listening ports")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(processSnapshot.listeningPorts) { endpoint in
                    SidecarStatusRow(
                        systemImage: "network",
                        title: "\(endpoint.address):\(endpoint.port)",
                        subtitle: "PID \(endpoint.pid)"
                    ) {
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(String(endpoint.port), forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy port")
                    }
                }
            }
        }
    }

    private func open(_ url: URL, in editor: SidecarEditor) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: editor.bundleIdentifier
        ) else {
            return
        }

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func refreshProcessLoop() async {
        var unchangedRefreshes = 0
        while !Task.isCancelled {
            let foregroundPID = surface.surfaceView.surfaceModel?.foregroundPID
            let refreshed = await SidecarProcessService.shared.snapshot(
                foregroundPID: foregroundPID
            )
            guard !Task.isCancelled else { return }
            let changed = refreshed != processSnapshot
            if changed {
                processSnapshot = refreshed
            }
            unchangedRefreshes = changed
                ? 0
                : min(unchangedRefreshes + 1, 2)
            let delay = unchangedRefreshes == 0
                ? Duration.seconds(1)
                : Duration.seconds(unchangedRefreshes + 1)

            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }
}

private struct SidecarProcessSection: View {
    let snapshot: SidecarProcessSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            SidecarSection("Process") {
                if snapshot.processes.isEmpty {
                    Text("No foreground process")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.processes) { process in
                        SidecarStatusRow(
                            systemImage: process.id == snapshot.processes.first?.id
                                ? "circle.fill"
                                : "arrow.turn.down.right",
                            title: process.name,
                            subtitle: "PID \(process.pid)"
                        ) {
                            Text(process.startedAt.relativeDuration(to: timeline.date))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

private extension URL {
    var abbreviatingWithTilde: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private extension Date {
    func relativeDuration(to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
