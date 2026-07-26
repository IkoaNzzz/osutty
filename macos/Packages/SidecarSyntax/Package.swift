// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SidecarSyntax",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SidecarSyntax", targets: ["SidecarSyntax"]),
    ],
    // SwiftTreeSitter 0.9 uses Tree-sitter 0.23 and language ABI 14. Keep grammar
    // revisions pinned to ABI-14 commits; newer grammar heads may require ABI 15.
    dependencies: [
        .package(
            url: "https://github.com/tree-sitter/swift-tree-sitter",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/alex-pinkus/tree-sitter-swift",
            revision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"
        ),
        .package(
            url: "https://github.com/maxxnino/tree-sitter-zig",
            revision: "a80a6e9be81b33b182ce6305ae4ea28e29211bd5"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-rust",
            revision: "3d087c3df25286140393ddecc339208fae107149"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-go",
            revision: "c350fa54d38af725c40d061a602ee3205ef1e072"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-c",
            revision: "e6fb5bc7bc806841762429dd32e075ddd84903e4"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-cpp",
            revision: "a0d1092dd724f7a6a62ac6bc755e65e6fceb19d4"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-javascript",
            revision: "a48cee89ea5a4866d8516ab344c1f4b35acf999f"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-typescript",
            revision: "75b3874edb2dc714fb1fd77a32013d0f8699989f"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-python",
            revision: "53639fbf35319f69a8ff63c48d9cc94aeee09816"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-bash",
            revision: "61b8e81486b9381a9f49d2bd2d695fc2f25b3984"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-json",
            revision: "001c28d7a29832b06b0e831ec77845553c89b56d"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-html",
            revision: "73a3947324f6efddf9e17c0ea58d454843590cc0"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-css",
            revision: "6e4e7885292b8dad18cccd845f838984181b264e"
        ),
        .package(
            url: "https://github.com/MDeiml/tree-sitter-markdown",
            revision: "31c557edb2702e753accdb21c95451d5b9877037"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-java",
            revision: "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11"
        ),
    ],
    targets: [
        .target(
            name: "SidecarSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterZig", package: "tree-sitter-zig"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
            ]
        ),
        .testTarget(
            name: "SidecarSyntaxTests",
            dependencies: ["SidecarSyntax"]
        ),
    ]
)
