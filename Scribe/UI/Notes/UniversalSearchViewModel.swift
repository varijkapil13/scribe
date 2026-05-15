// Scribe/UI/Notes/UniversalSearchViewModel.swift
import Foundation
import Combine

struct SearchResult: Identifiable {
    let id: String
    let title: String
    let snippet: String
    let destination: MainSelection
    let icon: String
}

struct SearchResultSection: Identifiable {
    let id: String
    let title: String
    let results: [SearchResult]
}

@MainActor
final class UniversalSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var sections: [SearchResultSection] = []

    private var debounceTask: Task<Void, Never>?
    private let noteStore: NoteStore
    private let taskStore: TaskStore

    init(noteStore: NoteStore = .shared,
         taskStore: TaskStore = .shared) {
        self.noteStore = noteStore
        self.taskStore = taskStore
    }

    func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    private func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)

        async let noteSec = searchNotes(q)
        async let taskSec = searchTasks(q)

        let results = await [noteSec, taskSec]
        sections = results.filter { !$0.results.isEmpty }
    }

    private func searchNotes(_ q: String) async -> SearchResultSection {
        let notes = (try? noteStore.searchNotes(query: q)) ?? []
        let results = notes.prefix(10).map { note in
            SearchResult(
                id: "note-\(note.id)",
                title: note.title.isEmpty ? "(Untitled)" : note.title,
                snippet: String(note.body.prefix(80)),
                destination: .note(note.id),
                icon: "note.text"
            )
        }
        return SearchResultSection(id: "notes", title: "Notes", results: Array(results))
    }

    private func searchTasks(_ q: String) async -> SearchResultSection {
        let tasks = (try? taskStore.searchTasks(query: q)) ?? []
        let results = tasks.prefix(10).map { task in
            SearchResult(
                id: "task-\(task.id)",
                title: task.title,
                snippet: String(task.notes.prefix(80)),
                destination: .tasks(.all),
                icon: "checkmark.circle"
            )
        }
        return SearchResultSection(id: "tasks", title: "Tasks", results: Array(results))
    }
}
