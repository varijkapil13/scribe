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
                Section {
                    ForEach(notes) { note in
                        Button(note.title.isEmpty ? "(Untitled)" : note.title) {
                            onNavigate(note.id)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    sectionHeader("Notes", count: notes.count)
                }
            }
            if !tasks.isEmpty {
                Section {
                    ForEach(tasks) { task in
                        Button(task.title) {
                            onNavigateToTask(task.id)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    sectionHeader("Tasks", count: tasks.count)
                }
            }
            if notes.isEmpty && tasks.isEmpty {
                ContentUnavailableView("No items tagged #\(tag)", systemImage: "tag")
            }
        }
        .navigationTitle("#\(tag)")
        .onAppear { load() }
    }

    /// Section header with a trailing count, matching the count styling used
    /// elsewhere (e.g. `TaskListView`'s batch controls).
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Text("(\(count))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func load() {
        notes = (try? NoteStore.shared.fetchNotes(withTag: tag)) ?? []
        tasks = (try? TaskStore.shared.fetchTasks(filter: .tag(tag))) ?? []
    }
}
