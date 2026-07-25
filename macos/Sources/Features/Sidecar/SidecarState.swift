import AppKit
import SwiftUI

/// Window-scoped presentation state for the terminal sidecar.
///
/// Keeping this state in one object lets TerminalView observe it without
/// spreading sidecar-specific properties throughout the terminal controller.
@MainActor
final class SidecarState: ObservableObject {
    nonisolated static let defaultWidth: CGFloat = 224

    @Published var isVisible: Bool
    @Published var selectedPanel: SidecarPanel
    @Published var width: CGFloat
    let outlineModel = SidecarOutlineModel()

    init(
        isVisible: Bool? = nil,
        selectedPanel: SidecarPanel = .info,
        width: CGFloat = SidecarState.defaultWidth
    ) {
        // UI/performance harnesses use an environment variable so Ghostty's
        // CLI configuration parser never sees a synthetic config field.
        let environmentStartsVisible =
            ProcessInfo.processInfo.environment["GHOSTTY_SIDECAR_VISIBLE"] == "1"
        self.isVisible = isVisible
            ?? environmentStartsVisible
        self.selectedPanel = selectedPanel
        self.width = width
    }

    func show(_ panel: SidecarPanel) {
        selectedPanel = panel
        isVisible = true
    }

    func hide() {
        isVisible = false
    }

    func toggle() {
        isVisible.toggle()
    }
}

enum SidecarPanel: String, CaseIterable, Identifiable {
    case info
    case outline
    case git
    case files

    var id: Self { self }

    var menuTag: Int {
        switch self {
        case .info: 0
        case .outline: 1
        case .git: 2
        case .files: 3
        }
    }

    init?(menuTag: Int) {
        switch menuTag {
        case 0: self = .info
        case 1: self = .outline
        case 2: self = .git
        case 3: self = .files
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .info: "Info"
        case .outline: "Outline"
        case .git: "Git"
        case .files: "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .outline: "list.bullet.indent"
        case .git: "arrow.triangle.branch"
        case .files: "folder"
        }
    }
}

enum SidecarShortcut {
    static let keyEquivalent = "s"
    static let modifierMask: NSEvent.ModifierFlags = [.control, .command]
    static let keyboardShortcut = KeyboardShortcut(
        KeyEquivalent("s"),
        modifiers: [.control, .command]
    )
}

@MainActor
enum SidecarMenuInstaller {
    static func install(before terminalInspector: NSMenuItem?) {
        guard let terminalInspector,
              let menu = terminalInspector.menu,
              !menu.items.contains(where: {
                  $0.action == #selector(BaseTerminalController.toggleSidecar(_:))
              }),
              let inspectorIndex = menu.items.firstIndex(where: {
                  $0 === terminalInspector
              }) else {
            return
        }

        let toggleItem = NSMenuItem(
            title: "Toggle Sidecar",
            action: #selector(BaseTerminalController.toggleSidecar(_:)),
            keyEquivalent: ""
        )
        toggleItem.image = NSImage(
            systemSymbolName: "sidebar.right",
            accessibilityDescription: "Toggle Sidecar"
        )
        toggleItem.keyEquivalent = SidecarShortcut.keyEquivalent
        toggleItem.keyEquivalentModifierMask = SidecarShortcut.modifierMask
        menu.insertItem(toggleItem, at: inspectorIndex)

        let panelMenu = NSMenu(title: "Sidecar Panel")
        for panel in SidecarPanel.allCases {
            let item = NSMenuItem(
                title: panel.title,
                action: #selector(BaseTerminalController.showSidecarPanel(_:)),
                keyEquivalent: ""
            )
            item.tag = panel.menuTag
            item.image = NSImage(
                systemSymbolName: panel.systemImage,
                accessibilityDescription: panel.title
            )
            panelMenu.addItem(item)
        }

        let panelItem = NSMenuItem(
            title: "Sidecar Panel",
            action: nil,
            keyEquivalent: ""
        )
        panelItem.submenu = panelMenu
        menu.insertItem(panelItem, at: inspectorIndex + 1)
    }
}
