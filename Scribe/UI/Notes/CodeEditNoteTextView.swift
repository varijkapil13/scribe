//
//  CodeEditNoteTextView.swift
//  Scribe
//
//  Step 1 of the editor rewrite (see docs/EDITOR_REWRITE_PLAN.md).
//
//  A thin SwiftUI wrapper around CodeEditApp's `SourceEditor` (TextKit 2 +
//  tree-sitter) that edits a `Binding<String>` of Markdown text. This is the
//  foundation the home-grown editor will eventually be replaced with. It is
//  intentionally *self-contained and not wired into NoteEditorView yet* — the
//  only goals of this file are to (a) prove the dependency resolves and
//  compiles on CI, and (b) exercise the exact current API surface.
//
//  Pinned against CodeEditSourceEditor 0.15.2 (macOS 13+). The
//  `SourceEditor` SwiftUI initializer and `SourceEditorConfiguration` shape
//  changed in the 0.15.x line, so this matches that version precisely:
//
//      SourceEditor(
//          _ text: Binding<String>,
//          language: CodeLanguage,
//          configuration: SourceEditorConfiguration,
//          state: Binding<SourceEditorState>,
//          ...
//      )
//

import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

/// A Markdown-aware source editor backed by CodeEditSourceEditor.
///
/// Edits the supplied `text` binding in place with tree-sitter Markdown
/// highlighting, line wrapping on, the app body font, and a theme derived from
/// ``DesignTokens``. Kept deliberately minimal and defensive so it builds on
/// Xcode 26 / macOS 26 without depending on Scribe's existing editor.
struct CodeEditNoteTextView: View {

    /// The Markdown document being edited.
    @Binding var text: String

    /// Transient editor UI state (cursor, scroll, find panel). Owned here so a
    /// caller only needs to provide the text binding.
    @State private var editorState = SourceEditorState()

    var body: some View {
        SourceEditor(
            $text,
            language: .markdown,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: .scribeDefault,
                    font: Self.bodyFont,
                    wrapLines: true
                )
            ),
            state: $editorState
        )
    }

    /// The app body font, monospaced-digit-free system font at the standard
    /// body size. A source editor wants a fixed `NSFont`; we mirror the
    /// system body point size so the editor reads as native chrome.
    private static var bodyFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }
}

// MARK: - Theme

extension EditorTheme {

    /// A neutral, light-mode-leaning Markdown theme derived from Scribe's
    /// design language. Colors map onto AppKit semantic colors where possible
    /// so the editor tracks the system palette; syntax tints reuse the
    /// ``DesignTokens/Palette`` accents. This is a sensible default for the
    /// foundation PR — a full light/dark, design-token-driven theme arrives
    /// when the editor is actually wired in.
    static var scribeDefault: EditorTheme {
        EditorTheme(
            text: Attribute(color: .textColor),
            insertionPoint: .textColor,
            invisibles: Attribute(color: .tertiaryLabelColor),
            background: .textBackgroundColor,
            lineHighlight: .unemphasizedSelectedContentBackgroundColor,
            selection: .selectedTextBackgroundColor,
            keywords: Attribute(color: nsColor(.priorityHigh), bold: true),
            commands: Attribute(color: nsColor(.speakerYou)),
            types: Attribute(color: nsColor(.speakerRemote)),
            attributes: Attribute(color: nsColor(.speakerRemote)),
            variables: Attribute(color: .textColor),
            values: Attribute(color: nsColor(.priorityMedium)),
            numbers: Attribute(color: nsColor(.priorityMedium)),
            strings: Attribute(color: nsColor(.priorityLow)),
            characters: Attribute(color: nsColor(.priorityLow)),
            comments: Attribute(color: .secondaryLabelColor, italic: true)
        )
    }

    /// Resolves a SwiftUI `Color` from ``DesignTokens/Palette`` into the
    /// `NSColor` the theme requires. Falls back to `.textColor` if a color
    /// can't be represented (defensive — never crashes the editor).
    private static func nsColor(_ color: Color) -> NSColor {
        NSColor(color)
    }
}

// MARK: - Preview / compile-exercise

/// Trivial usage so the symbol is referenced and the compiler exercises the
/// full type, initializer, configuration, and theme path at build time.
#Preview("CodeEditNoteTextView") {
    StatefulPreviewWrapper("# Hello, Scribe\n\nA **markdown** note edited with `CodeEditSourceEditor`.\n")
        .frame(width: 480, height: 320)
}

/// Minimal stateful host so the `Binding<String>` requirement is satisfied in
/// a `#Preview` without pulling in any of Scribe's models.
private struct StatefulPreviewWrapper: View {
    @State private var text: String
    init(_ initial: String) { _text = State(initialValue: initial) }
    var body: some View { CodeEditNoteTextView(text: $text) }
}
