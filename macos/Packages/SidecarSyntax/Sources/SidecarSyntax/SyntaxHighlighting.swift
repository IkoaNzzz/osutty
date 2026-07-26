import Foundation

public struct SyntaxHighlightSpan: Equatable, Sendable {
    public let range: NSRange
    public let captureName: String

    public init(range: NSRange, captureName: String) {
        self.range = range
        self.captureName = captureName
    }
}

public struct SyntaxHighlightUpdate: Equatable, Sendable {
    public let languageName: String
    public let invalidatedRanges: [NSRange]
    public let spans: [SyntaxHighlightSpan]

    public init(
        languageName: String,
        invalidatedRanges: [NSRange],
        spans: [SyntaxHighlightSpan]
    ) {
        self.languageName = languageName
        self.invalidatedRanges = invalidatedRanges
        self.spans = spans
    }
}

public protocol SyntaxHighlightingEngine: Sendable {
    func makeSession(fileName: String) throws -> (any SyntaxHighlightingSession)?
}

/// A stateful parser session. Callers must confine each session to one serial executor.
public protocol SyntaxHighlightingSession: AnyObject {
    func update(_ text: String) throws -> SyntaxHighlightUpdate
}
