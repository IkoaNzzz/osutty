import AppKit
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

struct SidecarEditor: Identifiable {
    let name: String
    let bundleIdentifier: String

    var id: String { bundleIdentifier }

    static let visualStudioCode = Self(
        name: "VS Code",
        bundleIdentifier: "com.microsoft.VSCode"
    )
    static let cursor = Self(
        name: "Cursor",
        bundleIdentifier: "com.todesktop.230313mzl4w4u92"
    )
    static let xcode = Self(
        name: "Xcode",
        bundleIdentifier: "com.apple.dt.Xcode"
    )
    static let zed = Self(
        name: "Zed",
        bundleIdentifier: "dev.zed.Zed"
    )
}

@MainActor
enum SidecarEditorCatalog {
    static let infoEditors = installed([
        .visualStudioCode,
        .cursor,
        .xcode,
        .zed,
    ])
    static let gitEditors = installed([
        .cursor,
        .visualStudioCode,
        .xcode,
        .zed,
    ])

    private static let installedBundleIdentifiers = Set(
        [
            SidecarEditor.visualStudioCode,
            .cursor,
            .xcode,
            .zed,
        ].compactMap { editor in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: editor.bundleIdentifier
            ) == nil ? nil : editor.bundleIdentifier
        }
    )

    private static func installed(_ editors: [SidecarEditor]) -> [SidecarEditor] {
        editors.filter { installedBundleIdentifiers.contains($0.bundleIdentifier) }
    }
}

struct SidecarToggleButton: View {
    @ObservedObject var presentation: SidecarPresentationState
    @ObservedObject var ghostty: Ghostty.App

    @State private var isHovering = false

    private var actionTitle: String {
        presentation.isVisible ? "Hide Sidecar" : "Show Sidecar"
    }

    private var helpTitle: String {
        guard let shortcut = ghostty.config.keyboardShortcut(
            for: SidecarBindingAction.toggle.configValue
        ) else {
            return actionTitle
        }
        return "\(actionTitle) (\(shortcut))"
    }

    var body: some View {
        ZStack {
            Color.clear

            Button {
                presentation.isVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .imageScale(.medium)
                    .foregroundStyle(presentation.isVisible ? Color.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                presentation.isVisible
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.06)
                            )
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpTitle)
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

struct SidecarSection<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)
                accessory
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SidecarSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
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

struct SidecarToolbarGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct SidecarToolbarTextButton: View {
    let title: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: SidecarMetrics.controlHeight)
                .background {
                    Rectangle()
                        .fill(hoverFill)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidecarFocusEffectDisabled()
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.55))
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
        .animation(SidecarMetrics.contentAnimation, value: isHovering)
    }

    private var hoverFill: Color {
        guard isEnabled, isHovering else { return .clear }
        return Color.primary.opacity(0.09)
    }
}

struct SidecarToolbarMenu<Content: View>: View {
    let help: String
    let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(help: String, @ViewBuilder content: () -> Content) {
        self.help = help
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.45))
                .frame(
                    width: SidecarMetrics.controlHeight,
                    height: SidecarMetrics.controlHeight
                )
                .background {
                    Rectangle()
                        .fill(hoverFill)
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
        .animation(SidecarMetrics.contentAnimation, value: isHovering)
    }

    private var hoverFill: Color {
        guard isEnabled, isHovering else { return .clear }
        return Color.primary.opacity(0.09)
    }
}

struct SidecarToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }
}

struct SidecarToolbarButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .opacity(isEnabled ? 1 : 0.5)
                .frame(width: SidecarMetrics.controlHeight, height: SidecarMetrics.controlHeight)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
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

    private var backgroundColor: Color {
        if isActive {
            return Color.accentColor.opacity(isEnabled ? 0.12 : 0.06)
        }
        guard isEnabled, isHovering else { return .clear }
        return Color.primary.opacity(0.07)
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
