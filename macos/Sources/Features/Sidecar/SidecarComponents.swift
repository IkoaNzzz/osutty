import SwiftUI

enum SidecarMetrics {
    static let contentPadding: CGFloat = 12
    static let compactContentPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 16
    static let controlHeight: CGFloat = 24
    static let rowHeight: CGFloat = 24
    static let rowIndent: CGFloat = 14

    static let tabAnimation = Animation.interactiveSpring(
        response: 0.22,
        dampingFraction: 0.86,
        blendDuration: 0.08
    )
    static let contentAnimation = Animation.easeOut(duration: 0.12)
    static let disclosureAnimation = Animation.easeInOut(duration: 0.16)
}

struct SidecarToggleButton: View {
    @ObservedObject var state: SidecarState

    @State private var isHovering = false

    private var actionTitle: String {
        state.isVisible ? "Hide Sidecar" : "Show Sidecar"
    }

    var body: some View {
        ZStack {
            Color.clear

            Button {
                state.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .imageScale(.medium)
                    .foregroundStyle(state.isVisible ? Color.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                state.isVisible
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.06)
                            )
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(actionTitle) (\(SidecarShortcut.keyboardShortcut))")
            .accessibilityLabel(actionTitle)
            .accessibilityIdentifier("sidecar-titlebar-toggle")
            // Keep a near-transparent accessibility target in the titlebar
            // while making the control visually absent until pointer hover.
            .opacity(isHovering ? 1 : 0.001)
        }
        .frame(width: 32, height: 28)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct SidecarSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SidecarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: SidecarMetrics.rowHeight)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.065 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidecarFocusEffectDisabled()
        .foregroundStyle(.tint)
        .help(title)
        .onHover { isHovering = $0 }
        .animation(SidecarMetrics.contentAnimation, value: isHovering)
    }
}

struct SidecarStatusRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
            trailing
        }
    }
}

extension SidecarStatusRow where Trailing == EmptyView {
    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct SidecarToolbarButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: SidecarMetrics.controlHeight, height: SidecarMetrics.controlHeight)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.12)
                                : Color.primary.opacity(isHovering ? 0.07 : 0)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidecarFocusEffectDisabled()
        .help(help)
        .onHover { isHovering = $0 }
        .animation(SidecarMetrics.contentAnimation, value: isHovering)
        .animation(SidecarMetrics.contentAnimation, value: isActive)
    }
}

private struct SidecarFocusEffectModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

extension View {
    /// Keep keyboard focus for Space/Quick Look without SwiftUI's blue halo.
    func sidecarFocusEffectDisabled() -> some View {
        modifier(SidecarFocusEffectModifier())
    }
}
