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

        async let noteSec = searchNotes(q)
        async let taskSec = searchTasks(q)
        async let transcriptSec = searchTranscripts(q)

        let results = await [noteSec, taskSec, transcriptSec]
        sections = results.filter { !$0.results.isEmpty }
    }

    private func searchNotes(_ q: String) async -> SearchResultSection {
        let notes = (try? noteStore.searchNotes(query: q)) ?? []
        return UniversalSearchSectionBuilder.notesSection(from: notes)
    }

    private func searchTasks(_ q: String) async -> SearchResultSection {
        let tasks = (try? taskStore.searchTasks(query: q)) ?? []
        return UniversalSearchSectionBuilder.tasksSection(from: tasks)
    }

    private func searchTranscripts(_ q: String) async -> SearchResultSection {
        guard !q.isEmpty else {
            return UniversalSearchSectionBuilder.transcriptsSection(from: [])
        }
        let fts = FTSQuery.escape(q)
        guard !fts.isEmpty else {
            return UniversalSearchSectionBuilder.transcriptsSection(from: [])
        }
        let hits = (try? transcriptStore.searchTranscripts(query: fts)) ?? []
        return UniversalSearchSectionBuilder.transcriptsSection(from: hits)
    }
}
