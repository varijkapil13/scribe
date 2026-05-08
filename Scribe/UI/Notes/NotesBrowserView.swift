// Scribe/UI/Notes/NotesBrowserView.swift
import SwiftUI

/// Two-pane notes browser: note list on the left, detail on the right.
/// Used for Inbox / All Notes / Notebook views so the list stays visible
/// while reading or editing a note.
struct NotesBrowserView: View {
    let scope: NoteListScope

    @State private var selectedNoteId: String?
    @State private var selectedNote: Note?

    var body: some View {
        HSplitView {
            NoteListView(scope: scope, selectedNoteId: $selectedNoteId)
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)

            Group {
                if let note = selectedNote {
                    NoteDetailView(note: note, onNavigate: { noteId in
                        selectedNoteId = noteId
                    })
                    .id(note.id)
                } else {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "note.text")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text("No Note Selected")
                            .font(DesignTokens.Typography.section)
                            .foregroundStyle(.secondary)
                        Text("Choose a note from the list.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: selectedNoteId) {
            guard let id = selectedNoteId else { selectedNote = nil; return }
            selectedNote = try? NoteStore.shared.fetchNote(id: id)
        }
    }
}
