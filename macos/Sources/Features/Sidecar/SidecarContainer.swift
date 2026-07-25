import SwiftUI

/// A floating secondary panel that stays outside of the terminal split tree.
///
/// The terminal split tree uses the remaining width, while the terminal theme
/// continues underneath the reserved area. This keeps every pane visible
/// without making a transparent hole around the floating card.
struct SidecarContainer<Primary: View, Sidecar: View>: View {
    @Binding private var isVisible: Bool
    @Binding private var sidecarWidth: CGFloat

    private let primary: Primary
    private let sidecar: Sidecar
    private let reservedAreaColor: Color
    private let reservedAreaOpacity: Double

    private let minimumSidecarWidth: CGFloat = 200
    private let maximumSidecarWidth: CGFloat = 320
    private let maximumSidecarFraction: CGFloat = 0.45
    private let cardInset: CGFloat = 8

    init(
        isVisible: Binding<Bool>,
        sidecarWidth: Binding<CGFloat>,
        reservedAreaColor: Color,
        reservedAreaOpacity: Double,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder sidecar: () -> Sidecar
    ) {
        _isVisible = isVisible
        _sidecarWidth = sidecarWidth
        self.reservedAreaColor = reservedAreaColor
        self.reservedAreaOpacity = reservedAreaOpacity
        self.primary = primary()
        self.sidecar = sidecar()
    }

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = clampedWidth(
                sidecarWidth,
                availableWidth: geometry.size.width
            )

            ZStack(alignment: .trailing) {
                if isVisible {
                    reservedAreaColor
                        .opacity(clampedOpacity(reservedAreaOpacity))
                        .frame(width: panelWidth + cardInset)
                        .frame(maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }

                HStack(spacing: 0) {
                    primary
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isVisible {
                        sidecar
                            .frame(width: panelWidth)
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, cardInset)
                            .padding(.trailing, cardInset)
                            .transition(
                                .move(edge: .trailing)
                                    .combined(with: .opacity)
                            )
                    }
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.16), value: isVisible)
        }
    }

    private func clampedWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximum = min(maximumSidecarWidth, availableWidth * maximumSidecarFraction)
        return min(max(width, min(minimumSidecarWidth, maximum)), maximum)
    }

    private func clampedOpacity(_ opacity: Double) -> Double {
        min(max(opacity, 0), 1)
    }
}

extension View {
    func terminalSidecar(
        state: SidecarState,
        surfaceView: Ghostty.SurfaceView?,
        ghostty: Ghostty.App
    ) -> some View {
        modifier(SidecarHostModifier(
            state: state,
            surfaceView: surfaceView,
            ghostty: ghostty
        ))
    }
}

private struct SidecarHostModifier: ViewModifier {
    @ObservedObject var state: SidecarState
    let surfaceView: Ghostty.SurfaceView?
    let ghostty: Ghostty.App

    @ViewBuilder
    func body(content: Content) -> some View {
        if let surfaceView {
            SidecarObservedSurfaceHost(
                content: content,
                state: state,
                surfaceView: surfaceView,
                ghostty: ghostty
            )
        } else {
            SidecarContainer(
                isVisible: $state.isVisible,
                sidecarWidth: $state.width,
                reservedAreaColor: ghostty.config.backgroundColor,
                reservedAreaOpacity: ghostty.config.backgroundOpacity
            ) {
                content
            } sidecar: {
                SidecarView(
                    state: state,
                    surfaceView: nil
                )
                .environmentObject(ghostty)
            }
        }
    }
}

private struct SidecarObservedSurfaceHost<Content: View>: View {
    let content: Content
    @ObservedObject var state: SidecarState
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let ghostty: Ghostty.App

    var body: some View {
        SidecarContainer(
            isVisible: $state.isVisible,
            sidecarWidth: $state.width,
            reservedAreaColor: surfaceView.backgroundColor
                ?? ghostty.config.backgroundColor,
            reservedAreaOpacity: surfaceView.derivedConfig.backgroundOpacity
        ) {
            content
        } sidecar: {
            SidecarView(
                state: state,
                surfaceView: surfaceView
            )
            .environmentObject(ghostty)
        }
    }
}
