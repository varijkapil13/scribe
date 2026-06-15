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
        // Native source-editor engine (TextKit 2 + tree-sitter). Step 1 of the
        // editor rewrite — see docs/EDITOR_REWRITE_PLAN.md. Mirrors the
        // `exactVersion` pin in project.yml so both build systems resolve the
        // same revision. Transitive deps (CodeEditTextView, CodeEditLanguages,
        // CodeEditSymbols, TextFormation, SwiftLintPlugins) resolve via SPM.
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", exact: "0.15.2"),
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeyboardShortcuts",
                .product(name: "Markdown", package: "swift-markdown"),
                // Compiled into the app target so CodeEditNoteTextView.swift
                // resolves under `swift test` (which builds `Scribe`) as well
                // as the xcodegen build. macOS-only; the iOS target in
                // project.yml deliberately does not depend on it.
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
            ],
            path: "Scribe"
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
