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
