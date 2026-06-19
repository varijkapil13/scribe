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
        // The SwiftPM target backs the logic-test job (`swift test`). The note
        // editor is now the CodeMirror 6 bundle hosted in a WKWebView
        // (WebMarkdownEditor + Scribe/Resources/Editor/). With the old native
        // CodeEditSourceEditor engine removed, NOTHING in the source tree depends
        // on a package whose asset bundle (CodeEditSymbols) failed to synthesize
        // `Bundle.module` under `swift test`. So the previous editor-exclusion
        // boundary — and the SwiftPMEntryShim that restored `@main` after
        // excluding ScribeApp — are gone: the full view layer (including the real
        // `@main ScribeApp`) compiles and links here again.
        //
        // WebMarkdownEditor imports only SwiftUI/WebKit/OSLog and loads its
        // assets from Bundle.main at runtime, degrading gracefully when they're
        // absent (as under `swift test`), so it needs no SwiftPM resource
        // declaration.
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeyboardShortcuts",
                .product(name: "Markdown", package: "swift-markdown"),
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
