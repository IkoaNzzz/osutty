import AppKit
import SwiftUI

struct SidecarEditorMenu: View {
    let editors: [SidecarEditor]
    let onOpen: (SidecarEditor) -> Void

    var body: some View {
        SidecarActionButton(
            title: "Open in…",
            systemImage: "arrow.up.forward.app",
            action: present
        )
        .help(
            editors.isEmpty
                ? "No supported editors installed"
                : "Open working directory in an editor"
        )
    }

    private func present() {
        guard
            let window = NSApp.keyWindow ?? NSApp.mainWindow,
            let contentView = window.contentView
        else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        if editors.isEmpty {
            let item = NSMenuItem(
                title: "No supported editors installed",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for editor in editors {
                menu.addItem(
                    SidecarEditorMenuItem(title: editor.name) {
                        onOpen(editor)
                    }
                )
            }
        }

        let location: NSPoint
        if let event = NSApp.currentEvent, event.window === window {
            location = contentView.convert(event.locationInWindow, from: nil)
        } else {
            location = NSPoint(
                x: contentView.bounds.maxX - 32,
                y: contentView.bounds.maxY - 120
            )
        }

        // Let the button's mouse-up finish before starting AppKit's nested
        // menu event loop, otherwise that same event immediately closes it.
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: location, in: contentView)
        }
    }
}

private final class SidecarEditorMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(
            title: title,
            action: #selector(performAction),
            keyEquivalent: ""
        )
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        handler()
    }
}
