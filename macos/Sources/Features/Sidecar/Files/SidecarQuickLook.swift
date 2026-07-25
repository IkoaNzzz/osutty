import AppKit
import Quartz
import SwiftUI

@MainActor
final class SidecarQuickLookController: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    private var previewURL: URL?

    func preview(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
        } else {
            preview(url)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

/// Installs the Files-panel-only Space shortcut used by Finder and Quick Look.
///
/// A local monitor is used instead of a global key handler so it is removed as
/// soon as the panel disappears. Text editing keeps normal Space behavior.
struct SidecarQuickLookKeyMonitor: NSViewRepresentable {
    let window: NSWindow?
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, action: action)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(for: window)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
        context.coordinator.window = window
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var isEnabled: Bool
        var action: () -> Void
        weak var window: NSWindow?
        private var monitor: Any?

        init(isEnabled: Bool, action: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.action = action
        }

        func install(for window: NSWindow?) {
            self.window = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                let isFilesWindowEvent = self.isEnabled && event.window === self.window
                let isPreviewPanelEvent = event.window is QLPreviewPanel
                guard isFilesWindowEvent || isPreviewPanelEvent,
                      event.keyCode == 49,
                      event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask),
                      !(event.window?.firstResponder is NSTextView) else {
                    return event
                }

                self.action()
                return nil
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            uninstall()
        }
    }
}
