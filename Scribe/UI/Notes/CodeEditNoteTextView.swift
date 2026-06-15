//
//  CodeEditNoteTextView.swift
//  Scribe
//
//  The LIVE note editor surface (editor rewrite — see docs/EDITOR_REWRITE_PLAN.md).
//
//  A SwiftUI wrapper around CodeEditApp's `SourceEditor` (TextKit 2 +
//  tree-sitter) that edits a `Binding<String>` of Markdown. It replaces the
//  home-grown `MarkdownEditorView` as the text surface inside ``NoteEditorView``.
//
//  Pinned against CodeEditSourceEditor 0.15.2 (macOS 13+). The
//  `SourceEditor` SwiftUI initializer and `SourceEditorConfiguration` shape
//  changed in the 0.15.x line, so this matches that version precisely.
//
//  ── SwiftPM build boundary ───────────────────────────────────────────────
//  This file imports CodeEditSourceEditor, whose transitive `CodeEditSymbols`
//  target cannot synthesize `Bundle.module` under `swift test`. It is therefore
//  excluded from the SwiftPM `Scribe` target (see Package.swift). Every SwiftUI
//  view file that *names* this type (or a type that names it) must be excluded
//  too; that exclusion chain is documented in Package.swift.
//

import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

/// A Markdown-aware source editor backed by CodeEditSourceEditor.
///
/// Edits the supplied `text` binding in place with tree-sitter Markdown
/// highlighting, line wrapping on, the app body font, and a light/dark theme
/// derived from ``DesignTokens``. The wrapper also wires the behaviours
/// ``NoteEditorView`` needs to reach parity with the old editor:
///
///   • interactive checkboxes (`- [ ]` / `- [x]` toggle on click),
///   • clickable `[[wiki links]]` routed through the host's navigation,
///   • a `/` slash-command query reported to the host (which shows the menu),
///   • `EditorActions` (bold / italic / lists / headings / …) that edit the
///     underlying source so the toolbar + format bubble + slash menu reuse a
///     single editing path.
///
/// Diagram / image folding (Mermaid, PlantUML, embedded images) is deliberately
/// NOT yet ported — CodeEditTextView uses a bespoke `TextAttachment` overlay
/// system rather than NSTextAttachment replacement, so that fold/unfold-on-caret
/// behaviour is a follow-up. See the PR notes.
struct CodeEditNoteTextView: View {

    /// The Markdown document being edited.
    @Binding var text: String

    /// The body font (per-note typeface / size), supplied by the host.
    var font: NSFont = .systemFont(ofSize: 15)

    /// Stable identity for the note; switching it resets transient editor state.
    var noteId: String? = nil

    /// `EditorActions` plumbing — the wrapper installs closures that edit the
    /// source so the toolbar, format bubble, and slash menu share one path.
    var actions: EditorActions? = nil

    /// Clicking a `[[wiki link]]` reports the inner anchor text here.
    var onWikiLinkNavigate: ((String) -> Void)? = nil

    /// Called as the user types a line-leading `/query`. The first argument is
    /// the query (without the `/`); the second is the caret rect in the
    /// editor's viewport coordinate space (origin top-left). A `.zero` rect
    /// means there is no open slash token — dismiss the menu.
    var onSlashTyped: ((String, CGRect) -> Void)? = nil

    /// Called as the user types inside an open `[[query` token (no closing
    /// `]]` yet). Empty string clears / dismisses the completion popup.
    var onWikiLinkTyped: ((String) -> Void)? = nil

    /// Reports the on-screen rect of a non-empty selection (viewport coords,
    /// origin top-left) or `nil` when the selection collapses.
    var onSelectionChanged: ((CGRect?) -> Void)? = nil

    /// Whether a slash menu is open. While true, the editor routes
    /// up/down/Return/Esc to the menu via the callbacks below.
    var slashMenuActive: Bool = false
    var onSlashMove: ((Bool) -> Void)? = nil
    var onSlashCommit: (() -> Bool)? = nil
    var onSlashDismiss: (() -> Bool)? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// Transient editor UI state (cursor, scroll, find panel). Owned here so a
    /// caller only needs to provide the text binding.
    @State private var editorState = SourceEditorState()

    /// The TextViewCoordinator is held by the editor's `TextViewController`
    /// *weakly* (see `WeakCoordinator`), so we must keep a strong reference
    /// across SwiftUI rebuilds. Created once; its `host` snapshot is refreshed
    /// every body evaluation so its callbacks never go stale.
    @State private var coordinator = NoteEditorCoordinator()

    var body: some View {
        // Refresh the coordinator's callback snapshot each render. `host` is a
        // value type; assigning it re-installs the EditorActions closures with
        // the latest bindings.
        coordinator.host = makeHostCallbacks()
        return SourceEditor(
            $text,
            language: .markdown,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: EditorTheme.scribe(for: colorScheme),
                    // Transparent background so the editor sits on Scribe's
                    // surface chrome rather than a hard theme panel.
                    useThemeBackground: false,
                    font: font,
                    // 1.25 keeps prose airy AND sizes the native insertion
                    // point to the body line height (the caret-size complaint
                    // about the old editor: CETV sizes the caret to the line
                    // fragment height, so it now tracks the body font).
                    lineHeightMultiple: 1.25,
                    wrapLines: true,
                    // Native macOS 14+ insertion indicator: correct caret size
                    // + blink, matched to the body font's line height.
                    useSystemCursor: true
                ),
                behavior: .init(isEditable: true),
                layout: .init(),
                peripherals: .init(
                    showGutter: false,
                    showMinimap: false,
                    showFoldingRibbon: false
                )
            ),
            state: $editorState,
            coordinators: [coordinator]
        )
    }

    private func makeHostCallbacks() -> NoteEditorCoordinator.Host {
        NoteEditorCoordinator.Host(
            noteId: noteId,
            actions: actions,
            onWikiLinkNavigate: onWikiLinkNavigate,
            onSlashTyped: onSlashTyped,
            onWikiLinkTyped: onWikiLinkTyped,
            onSelectionChanged: onSelectionChanged,
            slashMenuActive: slashMenuActive,
            onSlashMove: onSlashMove,
            onSlashCommit: onSlashCommit,
            onSlashDismiss: onSlashDismiss
        )
    }
}

// MARK: - Preview / compile-exercise

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
