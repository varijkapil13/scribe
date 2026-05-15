// Scribe/UI/TranscriptViewer/MoveToNotePicker.swift
import SwiftUI
import Combine

/// Sheet for picking a note to bind a transcript session to. Lists all
/// existing notes with a fuzzy filter, plus a "New note from this session"
/// shortcut.
struct MoveToNotePicker: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void
    let onCreateNew: () -> Void

    @State private var notes: [Note] = []
    @State private var notesCancellable: AnyCancellable?
    @State private var query: String = ""

    private var filtered: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                List {
                    Button {
                        onCreateNew()
                        dismiss()
                    } label: {
                        Label("New note from this session", systemImage: "plus.circle")
                    }

                    Section("Existing notes") {
                        ForEach(filtered) { note in
                            Button {
                                onSelect(note.id)
                                dismiss()
                            } label: {
                                Text(note.title.isEmpty ? "(Untitled)" : note.title)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle("Move to Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                notes = (try? NoteStore.shared.fetchAllNotes()) ?? []
                notesCancellable = NoteStore.shared.observeNotes()
                    .sink(receiveCompletion: { _ in },
                          receiveValue: { notes = $0 })
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }
}
