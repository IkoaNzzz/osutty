import AppKit
import SidecarSyntax
import SwiftUI

struct SidecarCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let fileName: String
    let backgroundColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = .init(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = .init(width: 12, height: 10)
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyTheme(to: textView)
        context.coordinator.applyPlainText(to: textView)
        context.coordinator.scheduleHighlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let oldFileName = context.coordinator.parent.fileName
        let oldIsLight = context.coordinator.parent.backgroundColor.isLightColor
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let configurationChanged = oldFileName != fileName
            || oldIsLight != backgroundColor.isLightColor
        context.coordinator.applyTheme(to: textView)
        if textView.string != text {
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            context.coordinator.isApplyingExternalText = false
            context.coordinator.applyPlainText(to: textView)
            context.coordinator.scheduleHighlight(resetSession: true)
        } else if configurationChanged {
            context.coordinator.applyPlainText(to: textView)
            context.coordinator.scheduleHighlight()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightWorkItem?.cancel()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let maximumHighlightedFileSize = 1_000_000
        private static let editorFont = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )

        var parent: SidecarCodeEditor
        weak var textView: NSTextView?
        var isApplyingExternalText = false
        var highlightWorkItem: DispatchWorkItem?

        private let syntaxQueue = DispatchQueue(
            label: "io.github.ikoanzzz.osutty.sidecar-syntax",
            qos: .userInitiated
        )
        private let syntaxWorker = SidecarSyntaxWorker()
        private var highlightGeneration = 0

        init(parent: SidecarCodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            scheduleHighlight()
        }

        func applyTheme(to textView: NSTextView) {
            let foregroundColor = SidecarSyntaxTheme(
                isLight: parent.backgroundColor.isLightColor
            ).foregroundColor
            textView.backgroundColor = parent.backgroundColor
            textView.insertionPointColor = foregroundColor
            textView.enclosingScrollView?.backgroundColor = parent.backgroundColor
            textView.typingAttributes = baseAttributes
        }

        func scheduleHighlight(resetSession: Bool = false) {
            highlightWorkItem?.cancel()
            highlightGeneration &+= 1

            guard let textView else { return }
            guard textView.string.utf8.count <= Self.maximumHighlightedFileSize else {
                applyPlainText(to: textView)
                return
            }

            let snapshot = textView.string
            let fileName = parent.fileName
            let generation = highlightGeneration
            let worker = syntaxWorker
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                let update = worker.highlight(
                    text: snapshot,
                    fileName: fileName,
                    resetSession: resetSession
                )
                DispatchQueue.main.async {
                    guard let self,
                          let textView,
                          self.highlightGeneration == generation,
                          textView.string == snapshot else { return }
                    guard let update else {
                        self.applyPlainText(to: textView)
                        return
                    }
                    self.apply(update, to: textView)
                }
            }
            highlightWorkItem = workItem
            syntaxQueue.asyncAfter(
                deadline: .now() + 0.08,
                execute: workItem
            )
        }

        func applyPlainText(to textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            let attributes = baseAttributes
            storage.setAttributes(
                attributes,
                range: NSRange(location: 0, length: storage.length)
            )
        }

        private func apply(_ update: SyntaxHighlightUpdate, to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let theme = SidecarSyntaxTheme(isLight: parent.backgroundColor.isLightColor)
            let storageRange = NSRange(location: 0, length: storage.length)
            let attributes = baseAttributes

            storage.beginEditing()
            for range in update.invalidatedRanges {
                let safeRange = NSIntersectionRange(range, storageRange)
                guard safeRange.length > 0 else { continue }
                storage.setAttributes(attributes, range: safeRange)
            }
            for span in update.spans {
                guard span.range.location >= 0,
                      NSMaxRange(span.range) <= storage.length,
                      let color = theme.color(for: span.captureName) else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: span.range
                )
            }
            storage.endEditing()
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            let theme = SidecarSyntaxTheme(isLight: parent.backgroundColor.isLightColor)
            return [
                .font: Self.editorFont,
                .foregroundColor: theme.foregroundColor,
            ]
        }
    }
}

private final class SidecarSyntaxWorker: @unchecked Sendable {
    private let engine: any SyntaxHighlightingEngine = TreeSitterSyntaxEngine.shared
    private var fileName = ""
    private var session: (any SyntaxHighlightingSession)?

    /// This mutable parser state is confined to its coordinator's serial syntax queue.
    func highlight(
        text: String,
        fileName: String,
        resetSession: Bool
    ) -> SyntaxHighlightUpdate? {
        if resetSession || self.fileName != fileName {
            self.fileName = fileName
            session = try? engine.makeSession(fileName: fileName)
        }
        return try? session?.update(text)
    }
}

private struct SidecarSyntaxTheme {
    let isLight: Bool

    var foregroundColor: NSColor {
        isLight ? .textColor : .white.withAlphaComponent(0.88)
    }

    func color(for captureName: String) -> NSColor? {
        let name = captureName.lowercased()
        if name == "none" || name.hasPrefix("spell") {
            return nil
        }
        if name.hasPrefix("comment") {
            return color(light: 0x3A7D44, dark: 0x7CCB7C)
        }
        if name.hasPrefix("string") || name.hasPrefix("character")
            || name.hasPrefix("text.literal") {
            return color(light: 0xA31515, dark: 0xF28B82)
        }
        if name.hasPrefix("keyword") || name.hasPrefix("conditional")
            || name.hasPrefix("repeat") || name.hasPrefix("exception") {
            return color(light: 0x7A3E9D, dark: 0xC792EA)
        }
        if name.hasPrefix("number") || name.hasPrefix("float")
            || name.hasPrefix("boolean") || name.hasPrefix("constant") {
            return color(light: 0x2358A5, dark: 0x82AAFF)
        }
        if name.hasPrefix("function") || name.hasPrefix("method")
            || name.hasPrefix("constructor") || name.hasPrefix("text.uri") {
            return color(light: 0x006B73, dark: 0x89DDFF)
        }
        if name.hasPrefix("type") || name.hasPrefix("class")
            || name.hasPrefix("namespace") || name.hasPrefix("module")
            || name.hasPrefix("text.title") {
            return color(light: 0x8A5200, dark: 0xFFCB6B)
        }
        if name.hasPrefix("tag") {
            return color(light: 0xB21F4B, dark: 0xF07178)
        }
        if name.hasPrefix("attribute") || name.hasPrefix("property")
            || name.hasPrefix("variable.member") {
            return color(light: 0x8A5200, dark: 0xFFCB6B)
        }
        if name.hasPrefix("variable.builtin") || name.hasPrefix("label")
            || name.hasPrefix("text.reference") {
            return color(light: 0x006B73, dark: 0x89DDFF)
        }
        return nil
    }

    private func color(light: UInt32, dark: UInt32) -> NSColor {
        let value = isLight ? light : dark
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
