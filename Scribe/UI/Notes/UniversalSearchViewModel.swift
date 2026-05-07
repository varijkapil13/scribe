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
    private let transcriptStore: TranscriptStore

    init(noteStore: NoteStore = .shared,
         taskStore: TaskStore = .shared,
         transcriptStore: TranscriptStore = .shared) {
        self.noteStore = noteStore
        self.taskStore = taskStore
        self.transcriptStore = transcriptStore
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

        let noteSec = await searchNotes(q)
        let taskSec = await searchTasks(q)
        let transcriptSec = await searchTranscripts(q)

        sections = [noteSec, taskSec, transcriptSec].filter { !$0.results.isEmpty }
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

    private func searchTranscripts(_ q: String) async -> SearchResultSection {
        guard !q.isEmpty else {
            return SearchResultSection(id: "transcripts", title: "Transcripts", results: [])
        }
        let matches = (try? transcriptStore.searchTranscripts(query: q)) ?? []
        let results = matches.prefix(5).map { (session, _) in
            SearchResult(
                id: "session-\(session.id)",
                title: session.title,
                snippet: "",
                destination: .transcript(session.id),
                icon: "waveform"
            )
        }
        return SearchResultSection(id: "transcripts", title: "Transcripts", results: Array(results))
    }
}
