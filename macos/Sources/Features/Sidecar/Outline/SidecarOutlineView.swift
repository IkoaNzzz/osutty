import SwiftUI

struct SidecarOutlineView: View {
    @ObservedObject var model: SidecarOutlineModel
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    var body: some View {
        Group {
            if model.isLoading, model.groups.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.groups.isEmpty {
                SidecarEmptyView(
                    title: "No Command Outline",
                    systemImage: "list.bullet.indent",
                    description: "Shell integration must provide OSC 133 semantic prompt markers."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let jumpError = model.jumpError {
                            Text(jumpError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        ForEach(model.groups) { group in
                            commandGroup(group)
                        }
                    }
                    .padding(.horizontal, SidecarMetrics.contentPadding)
                    .padding(.top, 5)
                    .padding(.bottom, SidecarMetrics.contentPadding)
                }
            }
        }
        .task(id: surfaceView.id) {
            while !Task.isCancelled {
                await model.refresh(surfaceView: surfaceView)
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func commandGroup(_ group: SidecarOutlineGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(abbreviate(group.workingDirectory) ?? "Unknown Directory")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let latestDate = group.latestDate {
                    Text(latestDate.relativeDescription(to: model.now))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)

            ForEach(group.items) { item in
                Button {
                    model.jump(to: item, surfaceView: surfaceView)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.command)
                            .font(.system(size: 12, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let duration = item.duration {
                            Text(duration.compactDuration)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(minHeight: SidecarMetrics.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to command in scrollback")
            }
        }
    }

    private func abbreviate(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~/" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count) + "/"
        }
        return path.hasSuffix("/") ? path : path + "/"
    }
}

private extension Date {
    func relativeDescription(to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

private extension TimeInterval {
    var compactDuration: String {
        if self < 1 { return "\(Int(self * 1_000))ms" }
        if self < 60 { return String(format: "%.1fs", self) }
        return "\(Int(self) / 60)m \(Int(self) % 60)s"
    }
}
