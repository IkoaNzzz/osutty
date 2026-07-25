import Combine
import Foundation

struct SidecarResourceMonitorValue: Equatable {
    var snapshot = SidecarProcessSnapshot.empty
    var history = SidecarResourceHistory()
    var hasResourceSample = false
}

/// Cached process and resource state for one terminal surface.
///
/// Each surface owns an independent observable entry so background sampling
/// does not invalidate the Info view for the currently focused split.
@MainActor
final class SidecarResourceMonitorEntry: ObservableObject {
    let surfaceID: UUID

    @Published private(set) var value = SidecarResourceMonitorValue()

    init(surfaceID: UUID) {
        self.surfaceID = surfaceID
    }

    func update(
        snapshot: SidecarProcessSnapshot,
        includesResources: Bool
    ) {
        var next = value
        next.snapshot = snapshot

        if includesResources {
            next.history.append(snapshot.resources)
            next.hasResourceSample = true
        } else if value.hasResourceSample {
            // A collapsed Monitor still refreshes process and port metadata.
            // Keep the latest resource values warm for the next expansion.
            next.snapshot.resources = value.snapshot.resources
        }

        guard next != value else { return }
        value = next
    }
}

/// Application-scoped, lazily activated resource monitor.
///
/// A single scheduler samples every registered split sequentially. This keeps
/// work bounded, prevents per-pane timer bursts, and lets focus changes reuse
/// the last snapshot and graph history immediately.
@MainActor
final class SidecarResourceMonitor: ObservableObject {
    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                nextSampleTimes.removeAll(keepingCapacity: true)
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    private var surfaces: [UUID: Weak<Ghostty.SurfaceView>] = [:]
    private var entries: [UUID: SidecarResourceMonitorEntry] = [:]
    private var emptyRefreshCounts: [UUID: Int] = [:]
    private var nextSampleTimes: [UUID: TimeInterval] = [:]
    private var activeSurfaceID: UUID?
    private var monitoringTask: Task<Void, Never>?

    deinit {
        monitoringTask?.cancel()
    }

    func register(_ surfaceViews: [Ghostty.SurfaceView]) {
        for surfaceView in surfaceViews {
            surfaces[surfaceView.id] = Weak(surfaceView)
            _ = cachedEntry(for: surfaceView.id)
        }
        pruneReleasedSurfaces()
    }

    func entry(
        for surfaceView: Ghostty.SurfaceView
    ) -> SidecarResourceMonitorEntry {
        surfaces[surfaceView.id] = Weak(surfaceView)
        pruneReleasedSurfaces()
        return cachedEntry(for: surfaceView.id)
    }

    func activate(_ surfaceView: Ghostty.SurfaceView) {
        let entry = entry(for: surfaceView)
        activeSurfaceID = surfaceView.id

        // Wake the shared scheduler only when this split has never received a
        // resource sample. Cached splits switch without restarting any work.
        if isEnabled, !entry.value.hasResourceSample {
            nextSampleTimes.removeValue(forKey: surfaceView.id)
            restartMonitoring()
        }
    }

    func refreshBasic(surfaceView: Ghostty.SurfaceView) async {
        let entry = entry(for: surfaceView)
        let refreshed = await SidecarProcessService.shared.snapshot(
            foregroundPID: surfaceView.surfaceModel?.foregroundPID,
            includeResources: false
        )
        guard !Task.isCancelled else { return }
        entry.update(snapshot: refreshed, includesResources: false)
    }

    private func cachedEntry(
        for surfaceID: UUID
    ) -> SidecarResourceMonitorEntry {
        if let entry = entries[surfaceID] {
            return entry
        }

        let entry = SidecarResourceMonitorEntry(surfaceID: surfaceID)
        entries[surfaceID] = entry
        return entry
    }

    private func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshRegisteredSurfaces()

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func restartMonitoring() {
        stopMonitoring()
        guard isEnabled else { return }
        startMonitoring()
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func refreshRegisteredSurfaces() async {
        pruneReleasedSurfaces()

        for surfaceID in orderedSurfaceIDs {
            guard !Task.isCancelled else { return }
            await refreshResourcesIfNeeded(surfaceID: surfaceID)
        }
    }

    private var orderedSurfaceIDs: [UUID] {
        let registered = Array(surfaces.keys)
        guard let activeSurfaceID,
              registered.contains(activeSurfaceID) else {
            return registered
        }
        return [activeSurfaceID] + registered.filter { $0 != activeSurfaceID }
    }

    private func refreshResourcesIfNeeded(surfaceID: UUID) async {
        let now = ProcessInfo.processInfo.systemUptime
        if let nextSampleTime = nextSampleTimes[surfaceID],
           now < nextSampleTime {
            return
        }

        guard let surfaceView = surfaces[surfaceID]?.value,
              let entry = entries[surfaceID] else {
            removeSurface(surfaceID)
            return
        }

        let refreshed = await SidecarProcessService.shared.snapshot(
            foregroundPID: surfaceView.surfaceModel?.foregroundPID,
            includeResources: true
        )
        guard !Task.isCancelled else { return }
        entry.update(snapshot: refreshed, includesResources: true)

        let emptyRefreshCount: Int
        if refreshed.processes.isEmpty {
            emptyRefreshCount = min(
                emptyRefreshCounts[surfaceID, default: 0] + 1,
                2
            )
        } else {
            emptyRefreshCount = 0
        }
        emptyRefreshCounts[surfaceID] = emptyRefreshCount
        nextSampleTimes[surfaceID] = ProcessInfo.processInfo.systemUptime
            + Double(emptyRefreshCount + 1)
    }

    private func pruneReleasedSurfaces() {
        for surfaceID in surfaces.compactMap({ key, value in
            value.value == nil ? key : nil
        }) {
            removeSurface(surfaceID)
        }
    }

    private func removeSurface(_ surfaceID: UUID) {
        surfaces.removeValue(forKey: surfaceID)
        entries.removeValue(forKey: surfaceID)
        emptyRefreshCounts.removeValue(forKey: surfaceID)
        nextSampleTimes.removeValue(forKey: surfaceID)
        if activeSurfaceID == surfaceID {
            activeSurfaceID = nil
        }
    }
}
