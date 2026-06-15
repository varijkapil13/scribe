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
        //
        // ── EDITOR EXCLUSION BOUNDARY ────────────────────────────────────
        // `CodeEditNoteTextView` / `CodeEditNoteSupport` import the editor.
        // Swift resolves every symbol in a module, so any file that *names* a
        // type defined in an excluded file must itself be excluded — this
        // cascades up the SwiftUI view tree:
        //
        //   CodeEditNoteTextView, CodeEditNoteSupport   (import the editor)
        //     ← NoteEditorView                          (instantiates the view)
        //         ← NoteDetailView, DailyNoteView       (instantiate NoteEditorView)
        //             ← NotesBrowserView, TodayView, MainWindowView
        //                 ← ScribeApp (@main)           (instantiates MainWindowView)
        //
        // The cascade stops at the SwiftUI VIEW layer. Logic the tests depend
        // on lives in its OWN files and stays in the target: NoteDetailViewModel,
        // SessionSelectionReducer, RecordingNavigationPolicy, ExportFileName,
        // NavigationCoordinator (those only NAME the views in comments, never in
        // code). Verified: no file under ScribeTests/ references an excluded file.
        //
        // Excluding `ScribeApp.swift` removes the app's real `@main`, so the
        // SwiftPM executable would have no entry point. `SwiftPMEntryShim.swift`
        // (gated on the SCRIBE_SPM_ENTRY define below, and excluded from
        // xcodebuild in project.yml) restores a trivial `@main` for `swift test`.
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeyboardShortcuts",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Scribe",
            exclude: [
                // Editor surface (imports CodeEditSourceEditor).
                "UI/Notes/CodeEditNoteTextView.swift",
                "UI/Notes/CodeEditNoteSupport.swift",
                // SwiftUI views that transitively reference the editor surface.
                "UI/Notes/NoteEditorView.swift",
                "UI/Notes/NoteDetailView.swift",
                "UI/Notes/DailyNoteView.swift",
                "UI/Notes/NotesBrowserView.swift",
                "UI/MainWindow/TodayView.swift",
                "UI/MainWindow/MainWindowView.swift",
                "App/ScribeApp.swift",
            ],
            swiftSettings: [
                // Enables the SwiftPM-only `@main` in SwiftPMEntryShim.swift.
                .define("SCRIBE_SPM_ENTRY")
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
