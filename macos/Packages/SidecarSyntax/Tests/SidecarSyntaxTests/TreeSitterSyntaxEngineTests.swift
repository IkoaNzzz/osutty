import XCTest
@testable import SidecarSyntax

final class TreeSitterSyntaxEngineTests: XCTestCase {
    func testLanguageDetectionUsesFileNameAndExtension() {
        XCTAssertEqual(TreeSitterLanguageRegistry.languageKey(forFileName: "main.swift"), "swift")
        XCTAssertEqual(TreeSitterLanguageRegistry.languageKey(forFileName: "component.tsx"), "tsx")
        XCTAssertEqual(TreeSitterLanguageRegistry.languageKey(forFileName: ".zshrc"), "bash")
        XCTAssertNil(TreeSitterLanguageRegistry.languageKey(forFileName: "README.txt"))
    }

    func testEverySupportedGrammarLoadsAndParses() throws {
        let fileNames = [
            "script.sh",
            "main.c",
            "main.cpp",
            "style.css",
            "main.go",
            "index.html",
            "Main.java",
            "app.js",
            "data.json",
            "README.md",
            "main.py",
            "main.rs",
            "main.swift",
            "app.ts",
            "app.tsx",
            "main.zig",
        ]

        for fileName in fileNames {
            let session = try XCTUnwrap(
                TreeSitterSyntaxEngine.shared.makeSession(fileName: fileName),
                "Failed to load grammar for \(fileName)"
            )
            _ = try session.update("value\n")
        }
    }

    func testSwiftHighlightsAreSyntaxAwareAndIncremental() throws {
        let session = try XCTUnwrap(
            TreeSitterSyntaxEngine.shared.makeSession(fileName: "Example.swift")
        )
        let firstText = "let untouched = 1\nlet message = \"hello\" // greeting\n"
        let first = try session.update(firstText)

        XCTAssertEqual(first.languageName, "Swift")
        XCTAssertTrue(first.spans.contains(capture: "keyword", text: "let", in: firstText))
        XCTAssertTrue(first.spans.contains(capture: "string", text: "hello", in: firstText))
        XCTAssertTrue(first.spans.contains(capture: "comment", text: "// greeting", in: firstText))

        let secondText = "let untouched = 1\nlet message = \"world\" // greeting\n"
        let second = try session.update(secondText)
        XCTAssertTrue(second.spans.contains(capture: "string", text: "world", in: secondText))
        XCTAssertTrue(second.invalidatedRanges.allSatisfy { $0.location > 0 })

        let emojiText = "let untouched = 1\nlet message = \"😀\" // greeting\n"
        _ = try session.update(emojiText)
        let changedEmojiText = "let untouched = 1\nlet message = \"😁\" // greeting\n"
        let emojiUpdate = try session.update(changedEmojiText)
        XCTAssertTrue(
            emojiUpdate.spans.contains(capture: "string", text: "😁", in: changedEmojiText)
        )
    }

    func testMarkdownFencedSwiftUsesNestedLanguage() throws {
        let session = try XCTUnwrap(
            TreeSitterSyntaxEngine.shared.makeSession(fileName: "README.md")
        )
        let text = """
        # Example

        ```swift
        let answer = 42
        ```
        """
        let update = try session.update(text)

        XCTAssertTrue(update.spans.contains(capture: "keyword", text: "let", in: text))
        XCTAssertTrue(update.spans.contains { $0.captureName.hasPrefix("text.title") })
    }

    func testPureDeletionInvalidatesAnAdjacentLine() throws {
        let session = try XCTUnwrap(
            TreeSitterSyntaxEngine.shared.makeSession(fileName: "Example.swift")
        )
        _ = try session.update("let value = 1 \n")

        let update = try session.update("let value = 1\n")

        XCTAssertFalse(update.invalidatedRanges.isEmpty)
        XCTAssertTrue(update.invalidatedRanges.contains { $0.location == 0 })
    }
}

private extension Array where Element == SyntaxHighlightSpan {
    func contains(capture: String, text expectedText: String, in text: String) -> Bool {
        contains { span in
            guard span.captureName.hasPrefix(capture),
                  let range = Range(span.range, in: text) else { return false }
            return String(text[range]) == expectedText
        }
    }
}
