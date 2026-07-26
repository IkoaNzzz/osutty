import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

public struct TreeSitterSyntaxEngine: SyntaxHighlightingEngine {
    public static let shared = TreeSitterSyntaxEngine()

    private let registry: TreeSitterLanguageRegistry

    init(registry: TreeSitterLanguageRegistry = .shared) {
        self.registry = registry
    }

    public func makeSession(fileName: String) throws -> (any SyntaxHighlightingSession)? {
        guard let language = registry.configuration(forFileName: fileName) else { return nil }
        let registry = registry
        let layerConfiguration = LanguageLayer.Configuration { languageName in
            registry.configuration(forLanguageName: languageName)
        }
        let layer = try LanguageLayer(
            languageConfig: language,
            configuration: layerConfiguration
        )
        return TreeSitterSyntaxSession(layer: layer)
    }
}

private final class TreeSitterSyntaxSession: SyntaxHighlightingSession {
    private let layer: LanguageLayer
    private var text = ""

    init(layer: LanguageLayer) {
        self.layer = layer
    }

    func update(_ newText: String) throws -> SyntaxHighlightUpdate {
        guard newText != text else {
            return try highlights(in: fullRangeSet(for: newText), text: newText)
        }

        let edit = try Self.inputEdit(from: text, to: newText)
        var invalidated = layer.didChangeContent(
            .init(string: newText),
            using: edit.inputEdit,
            resolveSublayers: true
        )
        invalidated.formUnion(
            Self.editedSet(for: edit.newRange, textLength: newText.utf16.count)
        )
        text = newText

        let expanded = Self.expandToLines(invalidated, text: newText)
        return try highlights(in: expanded, text: newText)
    }

    private func highlights(in ranges: IndexSet, text: String) throws -> SyntaxHighlightUpdate {
        guard !ranges.isEmpty else {
            return SyntaxHighlightUpdate(
                languageName: layer.languageName,
                invalidatedRanges: [],
                spans: []
            )
        }

        let namedRanges = try layer.highlights(
            in: ranges,
            provider: text.predicateTextProvider
        )
        let textLength = text.utf16.count
        let spans = namedRanges.compactMap { namedRange -> SyntaxHighlightSpan? in
            guard namedRange.range.location >= 0,
                  NSMaxRange(namedRange.range) <= textLength else { return nil }
            return SyntaxHighlightSpan(
                range: namedRange.range,
                captureName: namedRange.name
            )
        }

        return SyntaxHighlightUpdate(
            languageName: layer.languageName,
            invalidatedRanges: ranges.rangeView.map(NSRange.init),
            spans: spans
        )
    }

    private func fullRangeSet(for text: String) -> IndexSet {
        IndexSet(integersIn: 0..<text.utf16.count)
    }

    private static func inputEdit(
        from oldText: String,
        to newText: String
    ) throws -> (inputEdit: InputEdit, newRange: Range<Int>) {
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        guard oldUnits.count <= Int(UInt32.max / 2),
              newUnits.count <= Int(UInt32.max / 2) else {
            throw TreeSitterSyntaxError.documentTooLarge
        }

        var prefixLength = 0
        let commonLength = min(oldUnits.count, newUnits.count)
        while prefixLength < commonLength,
              oldUnits[prefixLength] == newUnits[prefixLength] {
            prefixLength += 1
        }
        if prefixLength > 0,
           prefixLength < commonLength,
           Self.isHighSurrogate(oldUnits[prefixLength - 1]) {
            prefixLength -= 1
        }

        var suffixLength = 0
        while suffixLength < oldUnits.count - prefixLength,
              suffixLength < newUnits.count - prefixLength,
              oldUnits[oldUnits.count - suffixLength - 1]
                == newUnits[newUnits.count - suffixLength - 1] {
            suffixLength += 1
        }
        let oldSuffixStart = oldUnits.count - suffixLength
        let newSuffixStart = newUnits.count - suffixLength
        let suffixSplitsSurrogate = suffixLength > 0
            && (Self.isLowSurrogate(oldUnits[oldSuffixStart])
                || Self.isLowSurrogate(newUnits[newSuffixStart]))
        if suffixSplitsSurrogate {
            suffixLength -= 1
        }

        let oldEnd = oldUnits.count - suffixLength
        let newEnd = newUnits.count - suffixLength
        let inputEdit = InputEdit(
            startByte: prefixLength * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: point(at: prefixLength, in: oldUnits),
            oldEndPoint: point(at: oldEnd, in: oldUnits),
            newEndPoint: point(at: newEnd, in: newUnits)
        )
        return (inputEdit, prefixLength..<newEnd)
    }

    private static func point(at offset: Int, in units: [UInt16]) -> Point {
        var row = 0
        var lineStart = 0
        if offset > 0 {
            for index in 0..<min(offset, units.count) where units[index] == 0x0A {
                row += 1
                lineStart = index + 1
            }
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }

    private static func isHighSurrogate(_ codeUnit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(codeUnit)
    }

    private static func isLowSurrogate(_ codeUnit: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(codeUnit)
    }

    private static func expandToLines(_ ranges: IndexSet, text: String) -> IndexSet {
        guard !text.isEmpty else { return IndexSet() }

        let string = text as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        var result = IndexSet()
        for range in ranges.rangeView {
            let safeRange = NSIntersectionRange(NSRange(range), fullRange)
            guard safeRange.length > 0 else { continue }
            let lineRange = string.lineRange(for: safeRange)
            result.insert(integersIn: lineRange.location..<NSMaxRange(lineRange))
        }
        return result
    }

    private static func editedSet(
        for range: Range<Int>,
        textLength: Int
    ) -> IndexSet {
        if !range.isEmpty {
            return IndexSet(integersIn: range)
        }
        guard textLength > 0 else { return IndexSet() }

        // A pure deletion has no post-edit range. Invalidate an adjacent code unit so
        // its complete line is restyled after the text storage closes the gap.
        return IndexSet(integer: min(range.lowerBound, textLength - 1))
    }
}

private enum TreeSitterSyntaxError: Error {
    case documentTooLarge
}
