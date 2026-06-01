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

    @State private var wikiQuery: String = ""
    @State private var showPopup: Bool = false
    @State private var suggestions: [Note] = []
    @State private var editorActions = EditorActions()

    // Slash command menu state.
    @State private var slashQuery: String = ""
    @State private var showSlashMenu: Bool = false
    @State private var slashCaretRect: CGRect = .zero
    @State private var slashHighlight: Int = 0

    // Selection-anchored format bubble state.
    @State private var selectionRect: CGRect? = nil

    // Per-note + default typography / measure preferences.
    @AppStorage(NotePageWidth.storageKey) private var pageWidthRaw: String = NotePageWidth.regular.rawValue
    @AppStorage(NoteTypeface.defaultStorageKey) private var defaultTypefaceRaw: String = NoteTypeface.system.rawValue
    /// The persisted per-note typeface override (empty = follow default).
    @State private var perNoteTypefaceRaw: String = ""

    // Fall back to the old always-on toolbar for accessibility / preference.
    @AppStorage("noteEditor.persistentToolbar") private var persistentToolbar: Bool = false

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pageWidth: NotePageWidth {
        NotePageWidth(rawValue: pageWidthRaw) ?? .regular
    }

    private var typeface: NoteTypeface {
        if let perNote = NoteTypeface(rawValue: perNoteTypefaceRaw) {
            return perNote
        }
        return NoteTypeface(rawValue: defaultTypefaceRaw) ?? .system
    }

    private var bodyFont: NSFont {
        typeface.baseFont(size: 15)
    }

    /// Dim floor for focus mode: keep the dimmed text readable under Increase
    /// Contrast (>= 0.6 so it still clears 4.5:1), otherwise calm 0.35.
    private var focusDimAlpha: CGFloat {
        contrast == .increased ? 0.6 : 0.35
    }

    var body: some View {
        VStack(spacing: 0) {
            // The persistent toolbar is an accessibility / preference fallback;
            // the floating bubble is the default. The toolbar is also kept while
            // focus mode is off so existing muscle memory still works for users
            // who opted in.
            if persistentToolbar && !focusModeEnabled {
                FormatToolbar(actions: editorActions)
            }

            ZStack(alignment: .topLeading) {
                MarkdownEditorView(
                    text: $text,
                    placeholder: "Write your note…",
                    font: bodyFont,
                    actions: editorActions,
                    extraHighlighter: highlightWikiLinks(_:),
                    onWikiLinkTyped: { query in
                        wikiQuery = query
                        if query.isEmpty {
                            showPopup = false
                        } else {
                            showPopup = true
                            Task { await loadSuggestions(query: query) }
                        }
                    },
                    onWikiLinkNavigate: { anchor in onNavigate(anchor) },
                    noteId: noteId,
                    pageMeasure: pageWidth.measure,
                    onSlashTyped: { query, caret in
                        // A valid caret rect means an open "/…" token at the
                        // caret (query may be empty right after typing "/"). A
                        // zero rect means no token — dismiss.
                        if caretRectIsValid(caret) {
                            if query != slashQuery { slashHighlight = 0 }
                            slashQuery = query
                            slashCaretRect = caret
                            showSlashMenu = true
                        } else {
                            showSlashMenu = false
                        }
                    },
                    onSelectionChanged: { rect in
                        // Animate only the show/hide transition, not the
                        // per-drag position updates (which would read as jitter).
                        let wasShowing = (selectionRect != nil)
                        let willShow = (rect != nil)
                        if wasShowing == willShow {
                            selectionRect = rect
                        } else {
                            withAnimationIfAllowed { selectionRect = rect }
                        }
                        if rect != nil { showSlashMenu = false }
                    },
                    slashMenuActive: showSlashMenu,
                    onSlashMove: { down in moveSlashHighlight(down: down) },
                    onSlashCommit: { commitHighlightedSlash() },
                    onSlashDismiss: { dismissSlashIfShowing() },
                    focusModeEnabled: focusModeEnabled,
                    focusDimAlpha: focusDimAlpha
                )

                // Wiki-link completion popup (unchanged behavior).
                if showPopup && !suggestions.isEmpty {
                    WikiLinkPopup(
                        suggestions: suggestions,
                        onPick: { note in
                            insertCompletion(note: note)
                            showPopup = false
                        },
                        onDismiss: { showPopup = false }
                    )
                    .padding(.top, 8)
                    .padding(.leading, 4)
                    .zIndex(1)
                }

                // Slash command menu, anchored below the caret.
                if showSlashMenu {
                    SlashCommandMenu(
                        query: slashQuery,
                        highlighted: $slashHighlight,
                        onPick: { command in commitSlash(command) }
                    )
                    .offset(x: slashMenuX, y: slashCaretRect.maxY + 4)
                    .zIndex(3)
                }

                // Selection-anchored format bubble.
                if let rect = selectionRect, !showSlashMenu {
                    FormatBubble(actions: editorActions)
                        .fixedSize()
                        .offset(x: bubbleX(for: rect), y: bubbleY(for: rect))
                        .zIndex(2)
                }
            }
        }
        .scribeFocusMenuToolbar(
            pageWidthRaw: $pageWidthRaw,
            perNoteTypefaceRaw: $perNoteTypefaceRaw,
            defaultTypefaceRaw: $defaultTypefaceRaw,
            persistentToolbar: $persistentToolbar
        )
        .onAppear { loadPerNoteTypeface() }
        .onChange(of: noteId) { _, _ in loadPerNoteTypeface() }
        .onChange(of: perNoteTypefaceRaw) { _, newValue in savePerNoteTypeface(newValue) }
    }

    // MARK: - Slash menu helpers

    private func caretRectIsValid(_ rect: CGRect) -> Bool {
        rect != .zero && rect.height > 0
    }

    /// Horizontal placement: clamp so the 280pt menu doesn't run off the left.
    private var slashMenuX: CGFloat {
        max(4, slashCaretRect.minX)
    }

    private func commitSlash(_ command: SlashCommand) {
        // Remove the typed "/query" first, then run the block verb on the now
        // clean line. Both route through EditorActions so the menu adds no new
        // editing path.
        editorActions.clearSlashToken?()
        command.run(editorActions)
        showSlashMenu = false
        slashQuery = ""
    }

    private func moveSlashHighlight(down: Bool) {
        let rows = SlashCommandMenu.filtered(for: slashQuery)
        guard !rows.isEmpty else { return }
        let next = slashHighlight + (down ? 1 : -1)
        slashHighlight = (next + rows.count) % rows.count
    }

    /// Commits the highlighted slash command. Returns true when the slash menu
    /// consumed Return (so the text view doesn't also insert a newline).
    private func commitHighlightedSlash() -> Bool {
        guard showSlashMenu else { return false }
        let rows = SlashCommandMenu.filtered(for: slashQuery)
        guard !rows.isEmpty else {
            // No match — let Return fall through to a normal newline, and close.
            showSlashMenu = false
            return false
        }
        let index = min(max(0, slashHighlight), rows.count - 1)
        commitSlash(rows[index])
        return true
    }

    private func dismissSlashIfShowing() -> Bool {
        guard showSlashMenu else { return false }
        showSlashMenu = false
        slashQuery = ""
        return true
    }

    // MARK: - Format bubble placement

    /// Horizontal: centre the (fixed-size) bubble over the selection, clamped
    /// to a small left margin.
    private func bubbleX(for rect: CGRect) -> CGFloat {
        max(4, rect.midX - 150)
    }

    /// Vertical: float just above the selection; if there's no room above,
    /// drop just below it instead.
    private func bubbleY(for rect: CGRect) -> CGFloat {
        let above = rect.minY - 44
        return above >= 0 ? above : rect.maxY + 6
    }

    private func withAnimationIfAllowed(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) { body() }
        }
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

    // MARK: - Wiki links (unchanged)

    private static let wikiHighlightRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)
    }()

    private func highlightWikiLinks(_ attrStr: NSMutableAttributedString) {
        let regex = Self.wikiHighlightRegex
        let str = attrStr.string
        let full = NSRange(str.startIndex..., in: str)
        regex.enumerateMatches(in: str, range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let fullRange = match.range
            attrStr.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: fullRange)
            attrStr.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: fullRange)
            // Set wikiAnchor attribute so mouseDown can read it directly — no scanning.
            if let captureRange = Range(match.range(at: 1), in: str) {
                let anchor = String(str[captureRange]).trimmingCharacters(in: .whitespaces)
                attrStr.addAttribute(.wikiAnchor, value: anchor, range: fullRange)
            }
        }
    }

    private func loadSuggestions(query: String) async {
        suggestions = (try? noteStore.searchNotes(query: query)) ?? []
    }

    private func insertCompletion(note: Note) {
        // Search backwards from the end of text for the last "[[<wikiQuery>"
        // occurrence. Using .backwards ensures we replace the instance closest
        // to the cursor (which is at the end of the live typing session), not
        // an earlier occurrence of the same partial text in the body.
        let needle = "[[" + wikiQuery
        guard let range = text.range(of: needle, options: .backwards) else { return }
        text = String(text[..<range.lowerBound]) + "[[\(note.title)]]"
        wikiQuery = ""
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

    private var pageWidth: NotePageWidth { NotePageWidth(rawValue: pageWidthRaw) ?? .regular }
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

private struct WikiLinkPopup: View {
    let suggestions: [Note]
    let onPick: (Note) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions.prefix(6)) { note in
                Button {
                    onPick(note)
                } label: {
                    Text(note.title.isEmpty ? "(Untitled)" : note.title)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onExitCommand { onDismiss() }
    }
}
