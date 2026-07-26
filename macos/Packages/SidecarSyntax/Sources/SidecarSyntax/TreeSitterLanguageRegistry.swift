import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterZig

final class TreeSitterLanguageRegistry: @unchecked Sendable {
    static let shared = TreeSitterLanguageRegistry()

    private typealias Factory = () throws -> LanguageConfiguration

    private let lock = NSLock()
    private var configurations: [String: LanguageConfiguration] = [:]
    private var unavailable: Set<String> = []

    private lazy var factories: [String: Factory] = [
        "bash": { try Self.configuration(tree_sitter_bash(), name: "Bash") },
        "c": { try Self.configuration(tree_sitter_c(), name: "C") },
        "cpp": { try Self.configuration(tree_sitter_cpp(), name: "CPP") },
        "css": { try Self.configuration(tree_sitter_css(), name: "CSS") },
        "go": { try Self.configuration(tree_sitter_go(), name: "Go") },
        "html": { try Self.configuration(tree_sitter_html(), name: "HTML") },
        "java": { try Self.configuration(tree_sitter_java(), name: "Java") },
        "javascript": {
            try Self.configuration(tree_sitter_javascript(), name: "JavaScript")
        },
        "json": { try Self.configuration(tree_sitter_json(), name: "JSON") },
        "markdown": {
            try Self.configuration(tree_sitter_markdown(), name: "Markdown")
        },
        "markdown_inline": {
            try Self.configuration(
                tree_sitter_markdown_inline(),
                name: "MarkdownInline",
                bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline"
            )
        },
        "python": { try Self.configuration(tree_sitter_python(), name: "Python") },
        "rust": { try Self.configuration(tree_sitter_rust(), name: "Rust") },
        "swift": { try Self.configuration(tree_sitter_swift(), name: "Swift") },
        "tsx": {
            try Self.configuration(
                tree_sitter_tsx(),
                name: "TSX",
                bundleName: "TreeSitterTypeScript_TreeSitterTSX"
            )
        },
        "typescript": {
            try Self.configuration(tree_sitter_typescript(), name: "TypeScript")
        },
        "zig": { try Self.configuration(tree_sitter_zig(), name: "Zig") },
    ]

    func configuration(forFileName fileName: String) -> LanguageConfiguration? {
        guard let key = Self.languageKey(forFileName: fileName) else { return nil }
        return configuration(forLanguageName: key)
    }

    func configuration(forLanguageName languageName: String) -> LanguageConfiguration? {
        guard let key = Self.languageAliases[languageName.lowercased()] else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let configuration = configurations[key] {
            return configuration
        }
        guard !unavailable.contains(key), let factory = factories[key] else { return nil }

        do {
            let configuration = try factory()
            configurations[key] = configuration
            return configuration
        } catch {
            unavailable.insert(key)
            return nil
        }
    }

    static func languageKey(forFileName fileName: String) -> String? {
        let lowercasedName = fileName.lowercased()
        if let key = fileNames[lowercasedName] {
            return key
        }

        let fileExtension = URL(fileURLWithPath: lowercasedName).pathExtension
        return fileExtensions[fileExtension]
    }

    private static func configuration(
        _ pointer: OpaquePointer,
        name: String,
        bundleName: String? = nil
    ) throws -> LanguageConfiguration {
        let language = Language(language: pointer)
        let resolvedBundleName = bundleName ?? "TreeSitter\(name)_TreeSitter\(name)"
        guard let queriesURL = queriesDirectory(bundleName: resolvedBundleName) else {
            throw TreeSitterLanguageRegistryError.missingQueries(resolvedBundleName)
        }
        return try LanguageConfiguration(language, name: name, queriesURL: queriesURL)
    }

    private static func queriesDirectory(bundleName: String) -> URL? {
        var containers = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ].compactMap { $0 }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            containers.append(bundle.bundleURL)
            if let resourceURL = bundle.resourceURL {
                containers.append(resourceURL)
            }
            containers.append(bundle.bundleURL.deletingLastPathComponent())
        }

        let fileManager = FileManager.default
        for container in containers {
            let bundleURL = container.lastPathComponent == "\(bundleName).bundle"
                ? container
                : container.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
            for relativePath in ["queries", "Contents/Resources/queries", "Resources/queries"] {
                let queriesURL = bundleURL.appendingPathComponent(relativePath, isDirectory: true)
                if fileManager.isReadableFile(atPath: queriesURL.path) {
                    return queriesURL
                }
            }
        }
        return nil
    }

    private static let fileNames: [String: String] = [
        ".bash_profile": "bash",
        ".bashrc": "bash",
        ".zprofile": "bash",
        ".zshrc": "bash",
    ]

    private static let fileExtensions: [String: String] = [
        "bash": "bash",
        "c": "c",
        "cc": "cpp",
        "cjs": "javascript",
        "cpp": "cpp",
        "cts": "typescript",
        "cxx": "cpp",
        "css": "css",
        "go": "go",
        "h": "c",
        "hh": "cpp",
        "hpp": "cpp",
        "htm": "html",
        "html": "html",
        "hxx": "cpp",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsx": "javascript",
        "m": "c",
        "markdown": "markdown",
        "md": "markdown",
        "mdown": "markdown",
        "mjs": "javascript",
        "mm": "cpp",
        "mts": "typescript",
        "py": "python",
        "pyi": "python",
        "pyw": "python",
        "rs": "rust",
        "sh": "bash",
        "swift": "swift",
        "ts": "typescript",
        "tsx": "tsx",
        "zig": "zig",
        "zsh": "bash",
    ]

    private static let languageAliases: [String: String] = [
        "bash": "bash",
        "c": "c",
        "c++": "cpp",
        "cpp": "cpp",
        "css": "css",
        "go": "go",
        "html": "html",
        "java": "java",
        "javascript": "javascript",
        "js": "javascript",
        "json": "json",
        "markdown": "markdown",
        "markdown_inline": "markdown_inline",
        "md": "markdown",
        "python": "python",
        "py": "python",
        "rust": "rust",
        "sh": "bash",
        "shell": "bash",
        "swift": "swift",
        "tsx": "tsx",
        "typescript": "typescript",
        "ts": "typescript",
        "zig": "zig",
        "zsh": "bash",
    ]
}

private enum TreeSitterLanguageRegistryError: Error {
    case missingQueries(String)
}
