// Scribe/UI/Notes/NoteEditorView.swift
import SwiftUI
import AppKit

struct NoteEditorView: View {

    @Binding var text: String
    var noteStore: NoteStore
    var noteId: String? = nil
    var onNavigate: (String) -> Void  // called with anchorText when user clicks a [[link]]
    /// Focus mode dims non-active blocks and (via the owner) hides surrounding
    /// chrome. The editor only owns the per-block dim; chrome hiding lives in
    /// the detail view.
    var focusModeEnabled: Bool = false

    // Per-note + default typography / measure preferences.
    @AppStorage(NotePageWidth.storageKey) private var pageWidthRaw: String = NotePageWidth.full.rawValue
    @AppStorage(NoteTypeface.defaultStorageKey) private var defaultTypefaceRaw: String = NoteTypeface.system.rawValue
    /// The persisted per-note typeface override (empty = follow default).
    @State private var perNoteTypefaceRaw: String = ""

    // Fall back to the old always-on toolbar for accessibility / preference.
    @AppStorage("noteEditor.persistentToolbar") private var persistentToolbar: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// Known note titles, refreshed when the editor appears / the note changes,
    /// so the web editor can style `[[wiki links]]` as resolved vs broken.
    @State private var knownTitles: [String] = []

    private var pageWidth: NotePageWidth {
        NotePageWidth(rawValue: pageWidthRaw) ?? .full
    }

    private var typeface: NoteTypeface {
        if let perNote = NoteTypeface(rawValue: perNoteTypefaceRaw) {
            return perNote
        }
        return NoteTypeface(rawValue: defaultTypefaceRaw) ?? .system
    }

    /// Body font size handed to the web editor. The CodeMirror prose theme owns
    /// the typeface itself (a system prose stack); we only sync the size so the
    /// page-width / typeface menu's size intent is honored.
    private var bodyFontSize: CGFloat {
        typeface.baseFont(size: 17).pointSize
    }

    // NOTE: the live note surface is now the CodeMirror 6 WebView editor
    // (`WebMarkdownEditor`) with Obsidian-style live preview, replacing the
    // rejected CodeEditSourceEditor surface. The slash-command menu, wiki-link
    // rendering/navigation, fenced mermaid/plantuml diagrams, and KaTeX math are
    // all handled inside the web editor (see editor-web/src/editor.js). Wiki-link
    // clicks bridge back via `onWikiLink`, resolved against the note titles and
    // navigated through `onNavigate` — the same path the rest of the app uses.
    // Selection-anchored format bubbles and focus-mode per-block dimming remain
    // deferred; `focusModeEnabled` still drives the surrounding chrome hide in
    // NoteDetailView.

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // The note text surface is the CodeMirror 6 markdown editor in a
                // WKWebView. It binds the raw markdown body and follows the
                // native color scheme; live-preview decorations are display-only
                // so the saved document stays raw markdown.
                WebMarkdownEditor(
                    text: $text,
                    colorScheme: colorScheme,
                    fontSize: bodyFontSize,
                    knownTitles: knownTitles,
                    onWikiLink: { anchor in onNavigate(anchor) }
                )
                // Full width by default. The finite presets (Regular/Wide)
                // centre the text column at the chosen reading measure
                // (Craft-style); `.full` applies no cap so the editor spans the
                // whole available width. The web editor's own prose column is
                // uncapped (maxWidth:none), so width is driven entirely here.
                .frame(maxWidth: pageWidth.capsWidth ? pageWidth.measure + 48 : .infinity)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .scribeFocusMenuToolbar(
            pageWidthRaw: $pageWidthRaw,
            perNoteTypefaceRaw: $perNoteTypefaceRaw,
            defaultTypefaceRaw: $defaultTypefaceRaw,
            persistentToolbar: $persistentToolbar
        )
        .onAppear {
            loadPerNoteTypeface()
            loadKnownTitles()
        }
        .onChange(of: noteId) { _, _ in
            loadPerNoteTypeface()
            loadKnownTitles()
        }
        .onChange(of: perNoteTypefaceRaw) { _, newValue in savePerNoteTypeface(newValue) }
    }

    /// Loads the set of known note titles for wiki-link resolution styling.
    private func loadKnownTitles() {
        knownTitles = (try? noteStore.allNoteTitles()) ?? []
    }

    // MARK: - Per-note typeface persistence

    private func loadPerNoteTypeface() {
        guard let noteId else { perNoteTypefaceRaw = ""; return }
        // Read from the note's `font:` frontmatter (Obsidian-compatible,
        // survives vault moves) — falling back to any legacy app-side value.
        if let font = NoteStore.shared.noteFont(id: noteId) {
            perNoteTypefaceRaw = font
        } else {
            perNoteTypefaceRaw = UserDefaults.standard.string(
                forKey: NoteTypeface.storageKey(forNoteId: noteId)
            ) ?? ""
        }
    }

    private func savePerNoteTypeface(_ value: String) {
        guard let noteId else { return }
        // Persist to frontmatter (portable); clear the legacy app-side key.
        NoteStore.shared.setNoteFont(id: noteId, value.isEmpty ? nil : value)
        UserDefaults.standard.removeObject(forKey: NoteTypeface.storageKey(forNoteId: noteId))
    }
}

// MARK: - View-menu / overflow hook

private extension View {
    /// Surfaces the page-width + typeface choices in the editor's overflow menu.
    /// A View-menu shortcut to flip page width lives on the spine (see
    /// integration hooks); this is the discoverable in-editor entry point.
    func scribeFocusMenuToolbar(
        pageWidthRaw: Binding<String>,
        perNoteTypefaceRaw: Binding<String>,
        defaultTypefaceRaw: Binding<String>,
        persistentToolbar: Binding<Bool>
    ) -> some View {
        self.toolbar {
            ToolbarItem(placement: .secondaryAction) {
                NoteEditorOverflowMenu(
                    pageWidthRaw: pageWidthRaw,
                    perNoteTypefaceRaw: perNoteTypefaceRaw,
                    defaultTypefaceRaw: defaultTypefaceRaw,
                    persistentToolbar: persistentToolbar
                )
            }
        }
    }
}

private struct NoteEditorOverflowMenu: View {
    @Binding var pageWidthRaw: String
    @Binding var perNoteTypefaceRaw: String
    @Binding var defaultTypefaceRaw: String
    @Binding var persistentToolbar: Bool

    private var pageWidth: NotePageWidth { NotePageWidth(rawValue: pageWidthRaw) ?? .full }
    private var defaultTypeface: NoteTypeface { NoteTypeface(rawValue: defaultTypefaceRaw) ?? .system }

    var body: some View {
        Menu {
            Section("Page Width") {
                ForEach(NotePageWidth.allCases) { width in
                    Button {
                        pageWidthRaw = width.rawValue
                    } label: {
                        Label(width.label, systemImage: width.symbol)
                        if pageWidth == width { Image(systemName: "checkmark") }
                    }
                }
            }
            Section("Typeface") {
                Button {
                    perNoteTypefaceRaw = ""
                } label: {
                    Text("Default (\(defaultTypeface.label))")
                    if perNoteTypefaceRaw.isEmpty { Image(systemName: "checkmark") }
                }
                Divider()
                ForEach(NoteTypeface.allCases) { face in
                    Button {
                        perNoteTypefaceRaw = face.rawValue
                    } label: {
                        Label(face.label, systemImage: face.symbol)
                        if perNoteTypefaceRaw == face.rawValue { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Toggle("Always Show Format Toolbar", isOn: $persistentToolbar)
        } label: {
            Label("Editor Options", systemImage: "textformat")
        }
        .help("Page width, typeface, and toolbar options")
        .accessibilityLabel("Editor options")
    }
}
