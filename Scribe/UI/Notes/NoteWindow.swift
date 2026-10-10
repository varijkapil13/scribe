// Scribe/UI/Notes/NoteWindow.swift
import SwiftUI

/// The value a standalone note window is opened with
/// (`openWindow(id: NoteWindowValue.windowID, value:)`). Codable so SwiftUI
/// can restore open note windows across launches.
struct NoteWindowValue: Codable, Hashable, Sendable {
    var noteId: String

    /// Scene id of the note `WindowGroup` (see `ScribeApp`).
    static let windowID = "note"
}

/// Content of a standalone note window: the note editor on its own, with the
/// same inspector, toolbar and menu commands as in the main window. Following
/// a `[[wiki link]]` or backlink replaces the window's note (and its restored
/// value) rather than spawning more windows.
struct NoteWindowRoot: View {
    @Binding var value: NoteWindowValue?
    @State private var note: Note?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let id = value?.noteId, let note, note.id == id {
                NoteDetailView(note: note, onNavigate: { value = NoteWindowValue(noteId: $0) })
                    .id(id)
            } else if didLoad || value == nil {
                ContentUnavailableView(
                    "Note not found",
                    systemImage: "note.text",
                    description: Text("This note may have been deleted.")
                )
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle(windowTitle)
        .task(id: value?.noteId) {
            didLoad = false
            if let id = value?.noteId {
                note = try? NoteStore.shared.fetchNote(id: id)
            } else {
                note = nil
            }
            didLoad = true
        }
    }

    private var windowTitle: String {
        guard let note else { return "Note" }
        return note.title.isEmpty ? "Untitled" : note.title
    }
}

/// "Open in New Window" for a note's context menu.
struct OpenNoteInNewWindowButton: View {
    let noteId: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: NoteWindowValue.windowID, value: NoteWindowValue(noteId: noteId))
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
    }
}
