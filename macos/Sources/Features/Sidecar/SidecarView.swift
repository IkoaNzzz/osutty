import AppKit
import SwiftUI

struct SidecarView: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @StateObject private var outlineModel = SidecarOutlineModel()
    @StateObject private var gitModel = SidecarGitModel()
    @StateObject private var filesModel = SidecarFilesModel()

    @ObservedObject var selection: SidecarSelectionState
    let surface: SidecarSurfaceContext?
    let resourceMonitor: SidecarResourceMonitor
    let quickEditorManager: SidecarQuickEditorManager
    let usesExternalChrome: Bool

    init(
        selection: SidecarSelectionState,
        surface: SidecarSurfaceContext?,
        resourceMonitor: SidecarResourceMonitor,
        quickEditorManager: SidecarQuickEditorManager,
        usesExternalChrome: Bool = false
    ) {
        self.selection = selection
        self.surface = surface
        self.resourceMonitor = resourceMonitor
        self.quickEditorManager = quickEditorManager
        self.usesExternalChrome = usesExternalChrome
    }

    private var theme: SidecarTheme {
        SidecarTheme(
            backgroundColor: ghostty.config.backgroundColor,
            backgroundOpacity: ghostty.config.backgroundOpacity
        )
    }

    var body: some View {
        SidecarChrome(
            theme: theme,
            usesExternalChrome: usesExternalChrome
        ) {
            VStack(spacing: 0) {
                SidecarTabBar(selection: $selection.selectedPanel)

                ZStack {
                    Group {
                        if let surface {
                            panelContent(surface: surface)
                        } else {
                            SidecarEmptyView(
                                title: "No Active Terminal",
                                systemImage: "terminal",
                                description: "Focus a terminal pane to show its details."
                            )
                        }
                    }
                    .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(SidecarMetrics.contentAnimation, value: selection.selectedPanel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal sidecar")
        .accessibilityIdentifier("terminal-sidecar")
    }

    @ViewBuilder
    private func panelContent(surface: SidecarSurfaceContext) -> some View {
        switch selection.selectedPanel {
        case .info:
            SidecarInfoView(surface: surface, monitor: resourceMonitor)

        case .outline:
            SidecarOutlineView(
                model: outlineModel,
                surface: surface
            )

        case .git:
            SidecarGitView(
                model: gitModel,
                surface: surface
            )

        case .files:
            SidecarFilesView(
                model: filesModel,
                surface: surface,
                quickEditorManager: quickEditorManager
            )
        }
    }
}

/// The small set of terminal-theme values that drive Sidecar presentation.
///
/// Keeping this value independent from `Ghostty.App` lets the production
/// chrome be rendered offscreen in unit tests without launching a terminal
/// window. All panel content still receives the environment selected here.
struct SidecarTheme {
    let backgroundColor: Color
    let backgroundOpacity: Double
    let colorScheme: ColorScheme

    init(backgroundColor: Color, backgroundOpacity: Double) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        self.colorScheme = NSColor(backgroundColor).isLightColor ? .light : .dark
    }
}

/// Native material card shared by the live Sidecar and its render tests.
struct SidecarChrome<Content: View>: View {
    let theme: SidecarTheme
    let usesExternalChrome: Bool
    let content: Content

    init(
        theme: SidecarTheme,
        usesExternalChrome: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.usesExternalChrome = usesExternalChrome
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if usesExternalChrome {
            content
                .environment(\.colorScheme, theme.colorScheme)
        } else {
            SidecarChromeSurface(
                backgroundColor: theme.backgroundColor,
                backgroundOpacity: theme.backgroundOpacity,
                shadowOpacity: theme.colorScheme == .dark ? 0.3 : 0.14
            ) {
                content
            }
            .environment(\.colorScheme, theme.colorScheme)
        }
    }
}

struct SidecarChromeSurface<Content: View>: View {
    let backgroundColor: Color
    let backgroundOpacity: Double
    let shadowOpacity: Double
    let usesMaterial: Bool
    let content: Content

    init(
        backgroundColor: Color,
        backgroundOpacity: Double,
        shadowOpacity: Double,
        usesMaterial: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.shadowOpacity = shadowOpacity
        self.usesMaterial = usesMaterial
        self.content = content()
    }

    var body: some View {
        content
            .background {
                ZStack {
                    if usesMaterial {
                        Rectangle()
                            .fill(.regularMaterial)
                        backgroundColor
                            .opacity(backgroundOpacity * 0.72)
                    } else {
                        backgroundColor
                            .opacity(max(backgroundOpacity, 0.94))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(shadowOpacity),
                radius: 8,
                y: 3
            )
    }
}

private struct SidecarTabBar: View {
    @Binding var selection: SidecarPanel
    @Namespace private var selectionCapsule
    @State private var hoveredPanel: SidecarPanel?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SidecarPanel.allCases) { panel in
                Button {
                    guard selection != panel else { return }
                    withAnimation(SidecarMetrics.tabAnimation) {
                        selection = panel
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: panel.systemImage)
                            .frame(width: 12)

                        if selection == panel {
                            Text(panel.title)
                                .fixedSize()
                                .transition(
                                    .opacity
                                        .combined(with: .scale(scale: 0.88, anchor: .leading))
                                )
                        }
                    }
                    .font(.system(
                        size: 11,
                        weight: selection == panel ? .semibold : .regular
                    ))
                    .foregroundStyle(selection == panel ? Color.primary : Color.secondary)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, selection == panel ? 6 : 0)
                    .background {
                        if selection == panel {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                                .matchedGeometryEffect(
                                    id: "sidecar-tab-selection",
                                    in: selectionCapsule
                                )
                        } else if hoveredPanel == panel {
                            Circle()
                                .fill(Color.primary.opacity(0.055))
                                .frame(width: 24, height: 24)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .sidecarFocusEffectDisabled()
                .onHover { isHovering in
                    hoveredPanel = isHovering ? panel : nil
                }
                .help(panel.title)
                .accessibilityLabel(panel.title)
                .accessibilityIdentifier("sidecar-tab-\(panel.rawValue)")
                .accessibilityAddTraits(selection == panel ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, SidecarMetrics.contentPadding)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .animation(SidecarMetrics.tabAnimation, value: selection)
        .animation(SidecarMetrics.contentAnimation, value: hoveredPanel)
    }
}

struct SidecarEmptyView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
