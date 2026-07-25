import SwiftUI

/// A floating secondary panel that stays outside of the terminal split tree.
///
/// The terminal split tree uses the remaining width, while the terminal theme
/// continues underneath the reserved area. This keeps every pane visible
/// without making a transparent hole around the floating card.
struct SidecarContainer<Primary: View, Sidecar: View>: View {
    @Environment(\.displayScale) private var displayScale

    @Binding private var isVisible: Bool
    @Binding private var sidecarWidth: CGFloat

    @State private var renderedSidecar: Bool
    @State private var sidecarChromeVisible: Bool
    @State private var isResizing = false
    @State private var resizeSession = SidecarResizeSession()

    private let primary: Primary
    private let sidecar: Sidecar
    private let reservedAreaColor: Color
    private let reservedAreaOpacity: Double
    private let usesExternalChrome: Bool

    init(
        isVisible: Binding<Bool>,
        sidecarWidth: Binding<CGFloat>,
        reservedAreaColor: Color,
        reservedAreaOpacity: Double,
        usesExternalChrome: Bool = false,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder sidecar: () -> Sidecar
    ) {
        _isVisible = isVisible
        _sidecarWidth = sidecarWidth
        _renderedSidecar = State(initialValue: isVisible.wrappedValue)
        _sidecarChromeVisible = State(initialValue: isVisible.wrappedValue)
        self.reservedAreaColor = reservedAreaColor
        self.reservedAreaOpacity = reservedAreaOpacity
        self.usesExternalChrome = usesExternalChrome
        self.primary = primary()
        self.sidecar = sidecar()
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: !isResizing)) { _ in
                let committedPanelWidth = SidecarLayout.width(
                    from: sidecarWidth,
                    horizontalTranslation: 0,
                    availableWidth: geometry.size.width,
                    displayScale: displayScale
                )
                let panelWidth = SidecarLayout.width(
                    from: sidecarWidth,
                    horizontalTranslation: isResizing
                        ? resizeSession.pendingTranslation
                        : 0,
                    availableWidth: geometry.size.width,
                    displayScale: displayScale
                )
                let reservedWidth = isVisible
                    ? SidecarLayout.reservedWidth(panelWidth: panelWidth)
                    : 0
                let committedReservedWidth = isVisible
                    ? SidecarLayout.reservedWidth(
                        panelWidth: committedPanelWidth
                    )
                    : 0
                let committedPrimaryWidth = max(
                    0,
                    geometry.size.width - committedReservedWidth
                )
                let previewPrimaryWidth = max(
                    0,
                    geometry.size.width - reservedWidth
                )

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
                            width: committedPrimaryWidth,
                            height: geometry.size.height
                        )
                        .frame(
                            width: previewPrimaryWidth,
                            height: geometry.size.height,
                            alignment: .leading
                        )
                        .clipped()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .leading
                        )
                        .animation(nil, value: isVisible)

                    if renderedSidecar {
                        Group {
                            if usesExternalChrome {
                                SidecarChromeSurface(
                                    backgroundColor: reservedAreaColor,
                                    backgroundOpacity: clampedOpacity(
                                        reservedAreaOpacity
                                    ),
                                    shadowOpacity: 0.22,
                                    usesMaterial: !isResizing
                                ) {
                                    sidecar
                                }
                            } else {
                                sidecar
                            }
                        }
                            .frame(width: panelWidth)
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, SidecarLayout.cardInset)
                            .padding(.trailing, SidecarLayout.cardInset)
                            .opacity(sidecarChromeVisible ? 1 : 0)
                            .offset(
                                x: sidecarChromeVisible
                                    ? 0
                                    : SidecarLayout.reservedWidth(
                                        panelWidth: panelWidth
                                    )
                            )
                    }

                    if isVisible {
                        resizeHandle(
                            panelWidth: panelWidth,
                            availableWidth: geometry.size.width
                        )
                        .offset(
                            x: -reservedWidth
                                + SidecarLayout.resizeHitWidth / 2
                        )
                    }
                }
                .transaction { transaction in
                    if isResizing {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
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
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .global
                )
                    .onChanged { value in
                        resizeSession.pendingTranslation =
                            value.translation.width
                        guard !isResizing else { return }

                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isResizing = true
                        }
                    }
                    .onEnded { value in
                        let finalWidth = SidecarLayout.width(
                            from: sidecarWidth,
                            horizontalTranslation: value.translation.width,
                            availableWidth: availableWidth,
                            displayScale: displayScale
                        )
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            sidecarWidth = finalWidth
                            isResizing = false
                        }
                        resizeSession.reset()
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

private final class SidecarResizeSession {
    var pendingTranslation: CGFloat = 0

    func reset() {
        pendingTranslation = 0
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
        availableWidth: CGFloat,
        displayScale: CGFloat = 1
    ) -> CGFloat {
        let width = clampedWidth(
            initialWidth - horizontalTranslation,
            availableWidth: availableWidth
        )
        let scale = max(1, displayScale)
        return (width * scale).rounded(.toNearestOrAwayFromZero) / scale
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
            presentation: state.presentation,
            surfaceView: surfaceView,
            ghostty: ghostty
        ))
    }
}

private struct SidecarHostModifier: ViewModifier {
    let state: SidecarState
    @ObservedObject var presentation: SidecarPresentationState
    let surfaceView: Ghostty.SurfaceView?
    let ghostty: Ghostty.App

    @ViewBuilder
    func body(content: Content) -> some View {
        if let surfaceView {
            SidecarObservedSurfaceHost(
                content: content,
                state: state,
                presentation: presentation,
                surfaceView: surfaceView,
                ghostty: ghostty
            )
        } else {
            SidecarContainer(
                isVisible: $presentation.isVisible,
                sidecarWidth: $presentation.width,
                reservedAreaColor: ghostty.config.backgroundColor,
                reservedAreaOpacity: ghostty.config.backgroundOpacity,
                usesExternalChrome: true
            ) {
                content
            } sidecar: {
                SidecarView(
                    selection: state.selection,
                    surface: nil,
                    usesExternalChrome: true
                )
                .environmentObject(ghostty)
            }
        }
    }
}

private struct SidecarObservedSurfaceHost<Content: View>: View {
    let content: Content
    let state: SidecarState
    @ObservedObject var presentation: SidecarPresentationState
    @StateObject private var surface: SidecarSurfaceContext
    let surfaceView: Ghostty.SurfaceView
    let ghostty: Ghostty.App

    init(
        content: Content,
        state: SidecarState,
        presentation: SidecarPresentationState,
        surfaceView: Ghostty.SurfaceView,
        ghostty: Ghostty.App
    ) {
        self.content = content
        self.state = state
        self.presentation = presentation
        self.surfaceView = surfaceView
        _surface = StateObject(
            wrappedValue: SidecarSurfaceContext(surfaceView: surfaceView)
        )
        self.ghostty = ghostty
    }

    var body: some View {
        SidecarContainer(
            isVisible: $presentation.isVisible,
            sidecarWidth: $presentation.width,
            reservedAreaColor: surface.backgroundColor
                ?? ghostty.config.backgroundColor,
            reservedAreaOpacity: surface.backgroundOpacity,
            usesExternalChrome: true
        ) {
            content
        } sidecar: {
            SidecarView(
                selection: state.selection,
                surface: surface,
                usesExternalChrome: true
            )
            .environmentObject(ghostty)
        }
        .task(id: surfaceView.id) {
            surface.update(surfaceView: surfaceView)
        }
    }
}
