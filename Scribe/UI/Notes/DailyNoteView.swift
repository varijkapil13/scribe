// Scribe/UI/Notes/DailyNoteView.swift
import SwiftUI

struct DailyNoteView: View {
    @State private var selectedNote: Note? = nil
    var onNavigate: (String) -> Void

    var body: some View {
        HSplitView {
            NoteCalendarView { date in
                selectedNote = try? NoteStore.shared.dailyNote(for: date)
            }
            .frame(minWidth: 240, maxWidth: 280)

            if let note = selectedNote {
                NoteDetailView(note: note, onNavigate: onNavigate)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "Select a day",
                    systemImage: "calendar",
                    description: Text("Pick a date to view or create that day's note.")
                )
            }
        }
        .onAppear {
            selectedNote = try? NoteStore.shared.dailyNote(for: Date())
        }
    }
}
