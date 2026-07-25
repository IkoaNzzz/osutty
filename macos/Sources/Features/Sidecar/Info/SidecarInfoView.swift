import AppKit
import SwiftUI

struct SidecarInfoView: View {
    @ObservedObject var surface: SidecarSurfaceContext

    private let monitor: SidecarResourceMonitor

    private var workingDirectory: URL? {
        guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true)
    }

    init(
        surface: SidecarSurfaceContext,
        monitor: SidecarResourceMonitor
    ) {
        self.surface = surface
        self.monitor = monitor
    }

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: SidecarMetrics.sectionSpacing
            ) {
                SidecarWorkspaceSection(
                    workingDirectory: workingDirectory
                )
                SidecarInfoLiveSections(
                    surface: surface,
                    monitor: monitor
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, SidecarMetrics.contentPadding)
        }
    }
}

private struct SidecarWorkspaceSection: View {
    let workingDirectory: URL?

    var body: some View {
        SidecarSection("Working Directory") {
            if let workingDirectory {
                Text(workingDirectory.abbreviatingWithTilde)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                SidecarActionButton(
                    title: "Copy Path",
                    systemImage: "doc.on.doc"
                ) {
                    copyPath(workingDirectory)
                }

                SidecarActionButton(
                    title: "Reveal in Finder",
                    systemImage: "folder"
                ) {
                    reveal(workingDirectory)
                }

                SidecarEditorMenu(
                    editors: SidecarEditorCatalog.infoEditors
                ) { editor in
                    open(workingDirectory, in: editor)
                }
            } else {
                Text("Waiting for shell integration to report a directory.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
}

private struct SidecarInfoLiveSections: View {
    @ObservedObject var surface: SidecarSurfaceContext
    @ObservedObject var monitor: SidecarResourceMonitor
    @ObservedObject private var monitorEntry: SidecarResourceMonitorEntry

    private var processSnapshot: SidecarProcessSnapshot {
        monitorEntry.value.snapshot
    }

    private var resourceHistory: SidecarResourceHistory {
        monitorEntry.value.history
    }

    private var refreshTaskID: String {
        "\(surface.id):\(monitor.isEnabled)"
    }

    init(
        surface: SidecarSurfaceContext,
        monitor: SidecarResourceMonitor
    ) {
        self.surface = surface
        self.monitor = monitor
        self.monitorEntry = monitor.entry(for: surface.surfaceView)
    }

    var body: some View {
        Group {
            SidecarResourceSection(
                snapshot: processSnapshot,
                history: resourceHistory,
                isExpanded: $monitor.isEnabled
            )
            .task(id: refreshTaskID) {
                monitor.activate(surface.surfaceView)
                await refreshProcessLoop()
            }

            SidecarProcessSection(
                snapshot: processSnapshot,
                showsResourceUsage: monitor.isEnabled
            )

            portsSection
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
                            copyPort(endpoint.port)
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

    private func copyPort(_ port: UInt16) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(port), forType: .string)
    }

    private func refreshProcessLoop() async {
        guard !monitor.isEnabled else { return }

        while !Task.isCancelled {
            await monitor.refreshBasic(surfaceView: surface.surfaceView)

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }
}

private struct SidecarCompactControlStyle: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .frame(height: 20)
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0))
            }
            .contentShape(Rectangle())
    }
}

private extension View {
    func sidecarCompactControl(isHovering: Bool) -> some View {
        modifier(SidecarCompactControlStyle(isHovering: isHovering))
    }
}

struct SidecarResourceHistory: Equatable {
    private static let capacity = 45

    private(set) var currentCPUPercent: [Double] = []
    private(set) var systemCPUPercent: [Double] = []
    private(set) var currentMemoryBytes: [Double] = []
    private(set) var systemMemoryUsedBytes: [Double] = []

    mutating func append(_ snapshot: SidecarResourceSnapshot) {
        currentCPUPercent.append(
            snapshot.cpuPercent ?? currentCPUPercent.last ?? 0
        )
        systemCPUPercent.append(
            snapshot.systemCPUPercent ?? systemCPUPercent.last ?? 0
        )
        currentMemoryBytes.append(Double(snapshot.memoryBytes))
        systemMemoryUsedBytes.append(
            Double(snapshot.systemMemoryUsedBytes)
        )
        trim(&currentCPUPercent)
        trim(&systemCPUPercent)
        trim(&currentMemoryBytes)
        trim(&systemMemoryUsedBytes)
    }

    private func trim(_ values: inout [Double]) {
        let overflow = values.count - Self.capacity
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}

private struct SidecarResourceSection: View {
    let snapshot: SidecarProcessSnapshot
    let history: SidecarResourceHistory
    @Binding var isExpanded: Bool

    @State private var isMonitorHovering = false

    var body: some View {
        SidecarSection("Resources", accessory: {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(
                            isExpanded
                                ? Color.green.opacity(0.8)
                                : Color.secondary.opacity(0.45)
                        )
                        .frame(width: 5, height: 5)

                    Text(isExpanded ? "Live" : "Monitor")
                        .font(.system(size: 9, weight: .medium))

                    Image(
                        systemName: isExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 7, weight: .semibold))
                }
                .sidecarCompactControl(isHovering: isMonitorHovering)
            }
            .buttonStyle(.plain)
            .sidecarFocusEffectDisabled()
            .help(
                isExpanded
                    ? "Pause monitoring and collapse"
                    : "Start live resource monitoring"
            )
            .onHover { isMonitorHovering = $0 }
            .animation(
                SidecarMetrics.contentAnimation,
                value: isMonitorHovering
            )
        }, content: {
            if isExpanded {
                if snapshot.processes.isEmpty {
                    Text("No foreground process")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    resourceCharts
                    ioMetrics
                    processSummary
                }
            }
        })
    }

    @ViewBuilder
    private var resourceCharts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                cpuChart
                    .frame(minWidth: 112)
                memoryChart
                    .frame(minWidth: 112)
            }

            VStack(spacing: 8) {
                cpuChart
                memoryChart
            }
        }
    }

    private var cpuChart: some View {
        SidecarResourceMetric(
            title: "CPU",
            series: [
                SidecarResourceSeries(
                    label: "Terminal",
                    value: SidecarResourceFormatter.percent(
                        snapshot.resources.cpuPercent
                    ),
                    samples: history.currentCPUPercent,
                    color: .accentColor
                ),
                SidecarResourceSeries(
                    label: "System",
                    value: SidecarResourceFormatter.percent(
                        snapshot.resources.systemCPUPercent
                    ),
                    samples: history.systemCPUPercent,
                    color: .yellow
                ),
            ],
            maximum: 100
        )
    }

    private var memoryChart: some View {
        SidecarResourceMetric(
            title: "Memory",
            series: [
                SidecarResourceSeries(
                    label: "Terminal",
                    value: SidecarResourceFormatter.bytes(
                        snapshot.resources.memoryBytes
                    ),
                    samples: history.currentMemoryBytes,
                    color: .accentColor
                ),
                SidecarResourceSeries(
                    label: "System",
                    value: SidecarResourceFormatter.bytes(
                        snapshot.resources.systemMemoryUsedBytes
                    ),
                    samples: history.systemMemoryUsedBytes,
                    color: .yellow
                ),
                SidecarResourceSeries(
                    label: "Total",
                    value: SidecarResourceFormatter.bytes(
                        snapshot.resources.systemMemoryTotalBytes
                    )
                ),
            ],
            maximum: Double(snapshot.resources.systemMemoryTotalBytes)
        )
    }

    private var ioMetrics: some View {
        HStack(spacing: 8) {
            SidecarResourceStat(
                title: "Read",
                systemImage: "arrow.down",
                value: SidecarResourceFormatter.rate(
                    snapshot.resources.readBytesPerSecond
                )
            )

            Divider()
                .frame(height: 24)

            SidecarResourceStat(
                title: "Write",
                systemImage: "arrow.up",
                value: SidecarResourceFormatter.rate(
                    snapshot.resources.writeBytesPerSecond
                )
            )
        }
        .padding(.horizontal, 2)
    }

    private var processSummary: some View {
        HStack(spacing: 6) {
            Label(
                "\(snapshot.processes.count) \(snapshot.processes.count == 1 ? "process" : "processes")",
                systemImage: "square.stack.3d.up"
            )

            Spacer(minLength: 4)

            Label(
                "\(snapshot.resources.threadCount) \(snapshot.resources.threadCount == 1 ? "thread" : "threads")",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct SidecarResourceSeries: Identifiable {
    let label: String
    let value: String
    var samples: [Double] = []
    var color: Color?

    var id: String { label }
}

private struct SidecarResourceMetric: View {
    let title: String
    let series: [SidecarResourceSeries]
    let maximum: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)

            SidecarSparkline(
                series: series,
                maximum: maximum
            )
            .frame(height: 28)

            VStack(spacing: 2) {
                ForEach(series) { item in
                    HStack(spacing: 4) {
                        if let color = item.color {
                            Circle()
                                .fill(color)
                                .frame(width: 4, height: 4)
                        } else {
                            Color.clear
                                .frame(width: 4, height: 4)
                        }

                        Text(item.label)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 2)

                        Text(item.value)
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.system(size: 9))
                    .lineLimit(1)
                }
            }
        }
        .padding(7)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            series.map { "\($0.label) \($0.value)" }
                .joined(separator: ", ")
        )
    }
}

private struct SidecarSparkline: View {
    let series: [SidecarResourceSeries]
    let maximum: Double?

    var body: some View {
        Canvas { context, size in
            let chartSeries = series.filter {
                $0.color != nil && $0.samples.count > 1
            }
            guard !chartSeries.isEmpty else { return }

            let observedMaximum = chartSeries
                .flatMap(\.samples)
                .max() ?? 0
            let upperBound = max(
                maximum ?? observedMaximum * 1.12,
                1
            )

            for item in chartSeries.reversed() {
                guard let color = item.color else { continue }
                let horizontalStep = size.width
                    / CGFloat(item.samples.count - 1)
                var line = Path()

                for (index, sample) in item.samples.enumerated() {
                    let normalized = min(max(sample / upperBound, 0), 1)
                    let point = CGPoint(
                        x: CGFloat(index) * horizontalStep,
                        y: size.height
                            - CGFloat(normalized) * size.height
                    )
                    if index == 0 {
                        line.move(to: point)
                    } else {
                        line.addLine(to: point)
                    }
                }

                context.stroke(
                    line,
                    with: .color(color),
                    style: StrokeStyle(
                        lineWidth: 1.1,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .accessibilityHidden(true)
    }
}

private struct SidecarResourceStat: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct SidecarProcessSection: View {
    let snapshot: SidecarProcessSnapshot
    let showsResourceUsage: Bool

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
                            systemImage: process.id
                                == snapshot.processes.first?.id
                                ? "circle.fill"
                                : "arrow.turn.down.right",
                            title: process.name,
                            subtitle: processSubtitle(
                                process,
                                now: timeline.date
                            )
                        ) {
                            if showsResourceUsage {
                                SidecarProcessUsage(process: process)
                            }
                        }
                    }
                }
            }
        }
    }

    private func processSubtitle(
        _ process: SidecarProcessInfo,
        now: Date
    ) -> String {
        var components = [
            "PID \(process.pid)",
            process.startedAt.relativeDuration(to: now),
        ]
        if process.threadCount > 0 {
            components.append(
                "\(process.threadCount) \(process.threadCount == 1 ? "thread" : "threads")"
            )
        }
        return components.joined(separator: " · ")
    }
}

private struct SidecarProcessUsage: View {
    let process: SidecarProcessInfo

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(SidecarResourceFormatter.percent(process.cpuPercent))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()

            Text(SidecarResourceFormatter.bytes(process.memoryBytes))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resource usage")
        .accessibilityValue(
            "\(SidecarResourceFormatter.percent(process.cpuPercent)) CPU, \(SidecarResourceFormatter.bytes(process.memoryBytes)) memory"
        )
    }
}

private enum SidecarResourceFormatter {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 10 {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.0f%%", value)
    }

    static func bytes(_ byteCount: UInt64) -> String {
        bytes(Double(byteCount))
    }

    static func bytes(_ byteCount: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(0, byteCount)
        var unitIndex = 0

        while value >= 1_024, unitIndex < units.count - 1 {
            value /= 1_024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        if value < 10 {
            return String(format: "%.1f %@", value, units[unitIndex])
        }
        return String(format: "%.0f %@", value, units[unitIndex])
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        return "\(bytes(bytesPerSecond))/s"
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
