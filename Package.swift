// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
        .package(url: "https://github.com/ggerganov/whisper.cpp", branch: "master"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "whisper", package: "whisper.cpp"),
                "KeyboardShortcuts",
            ],
            path: "Scribe"
        ),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"],
            path: "ScribeTests"
        ),
    ]
)
