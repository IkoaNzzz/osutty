import AppKit
import SwiftUI

@MainActor
final class SidecarPresentationState: ObservableObject {
    @Published var isVisible: Bool
    @Published var width: CGFloat

    init(isVisible: Bool, width: CGFloat) {
        self.isVisible = isVisible
        self.width = width
    }
}

@MainActor
final class SidecarSelectionState: ObservableObject {
    @Published var selectedPanel: SidecarPanel

    init(selectedPanel: SidecarPanel) {
        self.selectedPanel = selectedPanel
    }
}

/// Application-scoped state for the terminal Sidecar.
///
/// Presentation and panel selection are observed independently so switching a
/// panel cannot invalidate the terminal layout.
@MainActor
final class SidecarState {
    nonisolated static let defaultWidth: CGFloat = 224

    let presentation: SidecarPresentationState
    let selection: SidecarSelectionState

    var isVisible: Bool {
        get { presentation.isVisible }
        set { presentation.isVisible = newValue }
    }

    var selectedPanel: SidecarPanel {
        get { selection.selectedPanel }
        set { selection.selectedPanel = newValue }
    }

    var width: CGFloat {
        get { presentation.width }
        set { presentation.width = newValue }
    }

    init(
        isVisible: Bool? = nil,
        selectedPanel: SidecarPanel = .info,
        width: CGFloat = SidecarState.defaultWidth
    ) {
        // UI/performance harnesses use an environment variable so Ghostty's
        // CLI configuration parser never sees a synthetic config field.
        let environmentStartsVisible =
            ProcessInfo.processInfo.environment["GHOSTTY_SIDECAR_VISIBLE"] == "1"
        self.presentation = .init(
            isVisible: isVisible ?? environmentStartsVisible,
            width: width
        )
        self.selection = .init(selectedPanel: selectedPanel)
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

    var bindingAction: SidecarBindingAction {
        switch self {
        case .info: .info
        case .outline: .outline
        case .git: .git
        case .files: .files
        }
    }
}

enum SidecarBindingAction: String {
    case toggle
    case show
    case hide
    case info
    case outline
    case git
    case files

    var configValue: String {
        "sidecar:\(rawValue)"
    }
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

    static func bindings(
        before terminalInspector: NSMenuItem?
    ) -> [(action: String, item: NSMenuItem)] {
        guard let menu = terminalInspector?.menu else { return [] }

        var result: [(action: String, item: NSMenuItem)] = []
        if let toggleItem = menu.items.first(where: {
            $0.action == #selector(BaseTerminalController.toggleSidecar(_:))
        }) {
            result.append((
                SidecarBindingAction.toggle.configValue,
                toggleItem
            ))
        }

        guard let panelMenu = menu.items
            .first(where: { $0.submenu?.items.contains(where: {
                $0.action == #selector(BaseTerminalController.showSidecarPanel(_:))
            }) == true })?
            .submenu else {
            return result
        }

        result.append(contentsOf: panelMenu.items.compactMap { item in
            guard item.action == #selector(BaseTerminalController.showSidecarPanel(_:)),
                  let panel = SidecarPanel(menuTag: item.tag) else {
                return nil
            }
            return (panel.bindingAction.configValue, item)
        })
        return result
    }
}
