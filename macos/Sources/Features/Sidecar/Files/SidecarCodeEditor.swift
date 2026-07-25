import AppKit
import SwiftUI

struct SidecarCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let fileExtension: String
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
        context.coordinator.scheduleHighlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.applyTheme(to: textView)
        if textView.string != text {
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            context.coordinator.isApplyingExternalText = false
            context.coordinator.scheduleHighlight()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightWorkItem?.cancel()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SidecarCodeEditor
        weak var textView: NSTextView?
        var isApplyingExternalText = false
        var highlightWorkItem: DispatchWorkItem?

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
            let foregroundColor: NSColor = parent.backgroundColor.isLightColor
                ? .textColor
                : .white.withAlphaComponent(0.88)
            textView.backgroundColor = parent.backgroundColor
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
            textView.enclosingScrollView?.backgroundColor = parent.backgroundColor
        }

        func scheduleHighlight() {
            highlightWorkItem?.cancel()
            guard let textView, textView.string.utf8.count <= 1_000_000 else { return }

            let snapshot = textView.string
            let fileExtension = parent.fileExtension
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                DispatchQueue.global(qos: .userInitiated).async {
                    let spans = SidecarSyntaxHighlighter.spans(
                        in: snapshot,
                        fileExtension: fileExtension
                    )
                    DispatchQueue.main.async {
                        guard let self,
                              let textView,
                              textView.string == snapshot else { return }
                        self.apply(spans, to: textView)
                    }
                }
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.12,
                execute: workItem
            )
        }

        private func apply(_ spans: [SidecarHighlightSpan], to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let foregroundColor: NSColor = parent.backgroundColor.isLightColor
                ? .textColor
                : .white.withAlphaComponent(0.88)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: foregroundColor,
            ], range: fullRange)
            for span in spans where NSMaxRange(span.range) <= storage.length {
                storage.addAttribute(
                    .foregroundColor,
                    value: span.kind.color,
                    range: span.range
                )
            }
            storage.endEditing()
        }
    }
}

private struct SidecarHighlightSpan {
    enum Kind {
        case keyword
        case string
        case number
        case comment

        var color: NSColor {
            switch self {
            case .keyword: .systemPurple
            case .string: .systemRed
            case .number: .systemBlue
            case .comment: .systemGreen
            }
        }
    }

    let range: NSRange
    let kind: Kind
}

private enum SidecarSyntaxHighlighter {
    private static let stringPattern = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
    private static let numberPattern = #"\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#
    private static let slashCommentPattern = #"(?m)//.*$|(?s)/\*.*?\*/"#
    private static let hashCommentPattern = #"(?m)#.*$"#

    static func spans(in text: String, fileExtension: String) -> [SidecarHighlightSpan] {
        let ext = fileExtension.lowercased()
        var result: [SidecarHighlightSpan] = []
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        if let keywords = keywords[ext], !keywords.isEmpty {
            let escaped = keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            append(
                pattern: "\\b(?:\(escaped))\\b",
                kind: .keyword,
                text: text,
                range: fullRange,
                to: &result
            )
        }
        append(pattern: numberPattern, kind: .number, text: text, range: fullRange, to: &result)
        append(pattern: stringPattern, kind: .string, text: text, range: fullRange, to: &result)

        if hashCommentExtensions.contains(ext) {
            append(pattern: hashCommentPattern, kind: .comment, text: text, range: fullRange, to: &result)
        } else {
            append(pattern: slashCommentPattern, kind: .comment, text: text, range: fullRange, to: &result)
        }
        return result
    }

    private static func append(
        pattern: String,
        kind: SidecarHighlightSpan.Kind,
        text: String,
        range: NSRange,
        to result: inout [SidecarHighlightSpan]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let range = match?.range else { return }
            result.append(.init(range: range, kind: kind))
        }
    }

    private static let hashCommentExtensions: Set<String> = [
        "py", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml",
    ]

    private static let keywords: [String: [String]] = [
        "swift": ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"],
        "zig": ["align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "false", "fn", "for", "if", "inline", "noalias", "null", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "true", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while"],
        "js": ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "yield"],
        "ts": ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else", "enum", "export", "extends", "false", "for", "function", "if", "implements", "import", "interface", "let", "namespace", "new", "null", "private", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "var", "while"],
        "py": ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"],
        "java": ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try", "void", "volatile", "while"],
        "json": ["false", "null", "true"],
    ]
}
