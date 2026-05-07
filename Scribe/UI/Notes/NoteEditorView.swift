// Scribe/UI/Notes/NoteEditorView.swift
import SwiftUI
import AppKit

struct NoteEditorView: View {

    @Binding var text: String
    var noteStore: NoteStore
    var onNavigate: (String) -> Void  // called with anchorText when user clicks a [[link]]

    @State private var wikiQuery: String = ""
    @State private var showPopup: Bool = false
    @State private var suggestions: [Note] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkdownEditorView(
                text: $text,
                placeholder: "Write your note…",
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
                onWikiLinkNavigate: { anchor in onNavigate(anchor) }
            )

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
        }
    }

    private func highlightWikiLinks(_ attrStr: NSMutableAttributedString) {
        let pattern = #"\[\[([^\[\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let full = NSRange(attrStr.string.startIndex..., in: attrStr.string)
        regex.enumerateMatches(in: attrStr.string, range: full) { match, _, _ in
            guard let match else { return }
            attrStr.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
            attrStr.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: match.range)
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
