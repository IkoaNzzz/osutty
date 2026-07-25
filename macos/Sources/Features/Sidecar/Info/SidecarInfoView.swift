import AppKit
import SwiftUI

struct SidecarInfoView: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    @State private var processSnapshot = SidecarProcessSnapshot.empty
    @State private var currentDate = Date()
    @State private var installedEditors: [SidecarEditor] = []

    private var workingDirectory: URL? {
        guard let pwd = surfaceView.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SidecarMetrics.sectionSpacing) {
                workspaceSection
                processSection
                portsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, SidecarMetrics.contentPadding)
        }
        .task(id: surfaceView.id) {
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

                ForEach(installedEditors) { editor in
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
    private var processSection: some View {
        SidecarSection("Process") {
            if processSnapshot.processes.isEmpty {
                Text("No foreground process")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(processSnapshot.processes) { process in
                    SidecarStatusRow(
                        systemImage: process.id == processSnapshot.processes.first?.id
                            ? "circle.fill"
                            : "arrow.turn.down.right",
                        title: process.name,
                        subtitle: "PID \(process.pid)"
                    ) {
                        Text(process.startedAt.relativeDuration(to: currentDate))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
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
        installedEditors = SidecarEditor.known.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }

        while !Task.isCancelled {
            let foregroundPID = surfaceView.surfaceModel?.foregroundPID
            processSnapshot = await SidecarProcessService.shared.snapshot(
                foregroundPID: foregroundPID
            )
            currentDate = Date()

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}

private struct SidecarEditor: Identifiable {
    let name: String
    let bundleIdentifier: String

    var id: String { bundleIdentifier }

    static let known: [SidecarEditor] = [
        .init(name: "VS Code", bundleIdentifier: "com.microsoft.VSCode"),
        .init(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        .init(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
        .init(name: "Zed", bundleIdentifier: "dev.zed.Zed"),
    ]
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
