import AppKit
import SwiftUI

struct SidecarView: View {
    @EnvironmentObject private var ghostty: Ghostty.App

    @ObservedObject var state: SidecarState
    let surfaceView: Ghostty.SurfaceView?

    private var theme: SidecarTheme {
        SidecarTheme(
            backgroundColor: ghostty.config.backgroundColor,
            backgroundOpacity: ghostty.config.backgroundOpacity
        )
    }

    var body: some View {
        SidecarChrome(theme: theme) {
            VStack(spacing: 0) {
                SidecarTabBar(selection: $state.selectedPanel)

                ZStack {
                    Group {
                        if let surfaceView {
                            panelContent(surfaceView: surfaceView)
                                .id("\(surfaceView.id)-\(state.selectedPanel.rawValue)")
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
                .animation(SidecarMetrics.contentAnimation, value: state.selectedPanel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal sidecar")
        .accessibilityIdentifier("terminal-sidecar")
    }

    @ViewBuilder
    private func panelContent(surfaceView: Ghostty.SurfaceView) -> some View {
        switch state.selectedPanel {
        case .info:
            SidecarInfoView(surfaceView: surfaceView)

        case .outline:
            SidecarOutlineView(
                model: state.outlineModel,
                surfaceView: surfaceView
            )

        case .git:
            SidecarGitView(surfaceView: surfaceView)

        case .files:
            SidecarFilesView(surfaceView: surfaceView)
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
    let content: Content

    init(theme: SidecarTheme, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        content
            .background {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                    theme.backgroundColor
                        .opacity(theme.backgroundOpacity * 0.72)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(theme.colorScheme == .dark ? 0.3 : 0.14),
                radius: 8,
                y: 3
            )
            .environment(\.colorScheme, theme.colorScheme)
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
