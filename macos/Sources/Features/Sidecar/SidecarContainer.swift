import SwiftUI

/// A floating secondary panel that stays outside of the terminal split tree.
///
/// The terminal split tree uses the remaining width, while the terminal theme
/// continues underneath the reserved area. This keeps every pane visible
/// without making a transparent hole around the floating card.
struct SidecarContainer<Primary: View, Sidecar: View>: View {
    @Binding private var isVisible: Bool
    @Binding private var sidecarWidth: CGFloat

    @State private var renderedSidecar: Bool
    @State private var sidecarChromeVisible: Bool
    @GestureState private var dragTranslation: CGFloat = 0

    private let primary: Primary
    private let sidecar: Sidecar
    private let reservedAreaColor: Color
    private let reservedAreaOpacity: Double

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
        _renderedSidecar = State(initialValue: isVisible.wrappedValue)
        _sidecarChromeVisible = State(initialValue: isVisible.wrappedValue)
        self.reservedAreaColor = reservedAreaColor
        self.reservedAreaOpacity = reservedAreaOpacity
        self.primary = primary()
        self.sidecar = sidecar()
    }

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = SidecarLayout.width(
                from: sidecarWidth,
                horizontalTranslation: dragTranslation,
                availableWidth: geometry.size.width
            )
            let reservedWidth = isVisible
                ? SidecarLayout.reservedWidth(panelWidth: panelWidth)
                : 0

            ZStack(alignment: .trailing) {
                if isVisible {
                    reservedAreaColor
                        .opacity(clampedOpacity(reservedAreaOpacity))
                        .frame(width: reservedWidth)
                        .frame(maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                primary
                    .frame(
                        width: max(0, geometry.size.width - reservedWidth),
                        height: geometry.size.height
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .animation(nil, value: isVisible)

                if renderedSidecar {
                    sidecar
                        .frame(width: panelWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, SidecarLayout.cardInset)
                        .padding(.trailing, SidecarLayout.cardInset)
                        .opacity(sidecarChromeVisible ? 1 : 0)
                        .offset(
                            x: sidecarChromeVisible
                                ? 0
                                : SidecarLayout.reservedWidth(panelWidth: panelWidth)
                        )
                }

                if isVisible {
                    resizeHandle(
                        panelWidth: panelWidth,
                        availableWidth: geometry.size.width
                    )
                    .offset(
                        x: -reservedWidth + SidecarLayout.resizeHitWidth / 2
                    )
                }
            }
            .clipped()
            .task(id: isVisible) {
                if isVisible {
                    renderedSidecar = true
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(SidecarLayout.chromeAnimation) {
                        sidecarChromeVisible = true
                    }
                } else {
                    withAnimation(SidecarLayout.chromeAnimation) {
                        sidecarChromeVisible = false
                    }
                    try? await Task.sleep(for: SidecarLayout.animationDuration)
                    guard !Task.isCancelled, !isVisible else { return }
                    renderedSidecar = false
                }
            }
        }
    }

    private func resizeHandle(
        panelWidth: CGFloat,
        availableWidth: CGFloat
    ) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: SidecarLayout.resizeHitWidth)
            .frame(maxHeight: .infinity)
            .backport.pointerStyle(.resizeLeftRight)
            .onHover { isHovered in
                if #available(macOS 15, *) {
                    return
                }

                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragTranslation) { value, translation, transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                        translation = value.translation.width
                    }
                    .onEnded { value in
                        // Keep high-frequency drag updates local to this
                        // container. Publishing the application-scoped width
                        // on every pointer event invalidates every terminal
                        // tab and makes split Metal surfaces flicker.
                        sidecarWidth = SidecarLayout.width(
                            from: sidecarWidth,
                            horizontalTranslation: value.translation.width,
                            availableWidth: availableWidth
                        )
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sidecar resize divider")
            .accessibilityValue("\(Int(panelWidth)) points")
            .accessibilityHint("Drag to resize the Sidecar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat
                switch direction {
                case .increment:
                    adjustment = SidecarLayout.accessibilityWidthStep
                case .decrement:
                    adjustment = -SidecarLayout.accessibilityWidthStep
                @unknown default:
                    return
                }

                sidecarWidth = SidecarLayout.clampedWidth(
                    panelWidth + adjustment,
                    availableWidth: availableWidth
                )
            }
    }

    private func clampedOpacity(_ opacity: Double) -> Double {
        min(max(opacity, 0), 1)
    }
}

enum SidecarLayout {
    static let minimumWidth: CGFloat = 160
    static let maximumWidth: CGFloat = 520
    static let maximumWidthFraction: CGFloat = 0.5
    static let cardInset: CGFloat = 8
    static let resizeHitWidth: CGFloat = 10
    static let accessibilityWidthStep: CGFloat = 24
    static let animationDuration = Duration.milliseconds(160)
    static let chromeAnimation = Animation.easeOut(duration: 0.16)

    static func clampedWidth(
        _ width: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let maximum = min(
            maximumWidth,
            max(0, availableWidth) * maximumWidthFraction
        )
        return min(max(width, min(minimumWidth, maximum)), maximum)
    }

    static func reservedWidth(panelWidth: CGFloat) -> CGFloat {
        panelWidth + cardInset
    }

    static func width(
        from initialWidth: CGFloat,
        horizontalTranslation: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        clampedWidth(
            initialWidth - horizontalTranslation,
            availableWidth: availableWidth
        ).rounded(.toNearestOrAwayFromZero)
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
