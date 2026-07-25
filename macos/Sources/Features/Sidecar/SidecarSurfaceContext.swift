import Combine
import SwiftUI

/// The small, low-frequency subset of a terminal surface used by the Sidecar.
///
/// `Ghostty.SurfaceView` publishes pointer movement and renderer state at a much
/// higher frequency than the Sidecar needs. Projecting only these values keeps
/// terminal interaction from invalidating the Sidecar view hierarchy.
@MainActor
final class SidecarSurfaceContext: ObservableObject {
    private(set) var surfaceView: Ghostty.SurfaceView

    @Published private(set) var pwd: String?
    @Published private(set) var backgroundColor: Color?
    @Published private(set) var backgroundOpacity: Double

    var id: UUID { surfaceView.id }

    private var cancellables: Set<AnyCancellable> = []

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        self.pwd = surfaceView.pwd
        self.backgroundColor = surfaceView.backgroundColor
        self.backgroundOpacity = surfaceView.derivedConfig.backgroundOpacity
        observeSurface()
    }

    func update(surfaceView: Ghostty.SurfaceView) {
        guard surfaceView.id != self.surfaceView.id else { return }

        cancellables.removeAll()
        self.surfaceView = surfaceView
        pwd = surfaceView.pwd
        backgroundColor = surfaceView.backgroundColor
        backgroundOpacity = surfaceView.derivedConfig.backgroundOpacity
        observeSurface()
    }

    private func observeSurface() {
        surfaceView.$pwd
            .removeDuplicates()
            .sink { [weak self] in self?.pwd = $0 }
            .store(in: &cancellables)

        surfaceView.$backgroundColor
            .removeDuplicates()
            .sink { [weak self] in self?.backgroundColor = $0 }
            .store(in: &cancellables)

        surfaceView.$derivedConfig
            .map(\.backgroundOpacity)
            .removeDuplicates()
            .sink { [weak self] in self?.backgroundOpacity = $0 }
            .store(in: &cancellables)
    }
}
