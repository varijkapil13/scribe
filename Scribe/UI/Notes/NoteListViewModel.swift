// Scribe/UI/Notes/NoteListViewModel.swift
import Foundation
import Combine

@MainActor
final class NoteListViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var searchText: String = ""
    @Published var errorMessage: String? = nil

    private let store: NoteStore
    private var cancellables = Set<AnyCancellable>()

    init(store: NoteStore = .shared) {
        self.store = store
        store.observeNotes()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] notes in self?.notes = notes })
            .store(in: &cancellables)
    }

    var filteredNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        let lower = q.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(lower) || $0.body.lowercased().contains(lower)
        }
    }

    func createNote() -> Note? {
        try? store.createNote(title: "", body: "", tags: [])
    }

    func deleteNote(id: String) {
        do { try store.deleteNote(id: id) }
        catch { errorMessage = error.localizedDescription }
    }
}
