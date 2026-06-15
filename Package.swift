// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        // The SwiftPM target backs the logic-test job (`swift test`) only. The
        // native editor engine (CodeEditSourceEditor, TextKit 2 + tree-sitter)
        // is intentionally NOT a SwiftPM dependency: under `swift test` its
        // transitive CodeEditSymbols target fails to synthesize `Bundle.module`
        // for its asset bundle. The editor is built and gated exclusively by
        // the xcodegen/xcodebuild app build (project.yml), so editor sources
        // that import it are excluded here. See docs/EDITOR_REWRITE_PLAN.md.
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeyboardShortcuts",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Scribe",
            exclude: [
                "UI/Notes/CodeEditNoteTextView.swift",
            ]
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: [
                "Scribe",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "ScribeTests"
        ),
    ]
)
