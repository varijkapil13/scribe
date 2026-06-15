// Scribe/UI/Notes/TaggedContentView.swift
import SwiftUI

struct TaggedContentView: View {
    let tag: String
    var onNavigate: (String) -> Void
    var onNavigateToTask: (String) -> Void

    @State private var notes: [Note] = []
    @State private var tasks: [TodoTask] = []

    var body: some View {
        List {
            if !notes.isEmpty {
                Section("Notes") {
                    ForEach(notes) { note in
                        Button(note.title.isEmpty ? "(Untitled)" : note.title) {
                            onNavigate(note.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !tasks.isEmpty {
                Section("Tasks") {
                    ForEach(tasks) { task in
                        Button(task.title) {
                            onNavigateToTask(task.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if notes.isEmpty && tasks.isEmpty {
                ContentUnavailableView("No items tagged #\(tag)", systemImage: "tag")
            }
        }
        .navigationTitle("#\(tag)")
        .onAppear { load() }
    }

    private func load() {
        notes = (try? NoteStore.shared.fetchNotes(withTag: tag)) ?? []
        tasks = (try? TaskStore.shared.fetchTasks(filter: .tag(tag))) ?? []
    }
}
