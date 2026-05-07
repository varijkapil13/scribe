// Scribe/UI/Notes/NoteListViewModel.swift
import Foundation
import Combine

enum NoteListScope {
    case all
    case inbox
    case notebook(String)
}

@MainActor
final class NoteListViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var searchText: String = ""
    @Published var errorMessage: String? = nil

    private let store: NoteStore
    private var cancellables = Set<AnyCancellable>()
    var scope: NoteListScope = .all

    init(store: NoteStore = .shared, scope: NoteListScope = .all) {
        self.store = store
        self.scope = scope
        store.observeNotes()
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] _ in self?.loadNotes() })
            .store(in: &cancellables)
        loadNotes()
    }

    var filteredNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return (try? store.searchNotes(query: q)) ?? notes
    }

    func createNote() -> Note? {
        let notebookId: String?
        if case .notebook(let id) = scope { notebookId = id } else { notebookId = nil }
        return try? store.createNote(title: "", body: "", tags: [], notebookId: notebookId)
    }

    func deleteNote(id: String) {
        do { try store.deleteNote(id: id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func loadNotes() {
        do {
            notes = switch scope {
            case .all:             try store.fetchAllNotes()
            case .inbox:           try store.fetchInboxNotes()
            case .notebook(let id): try store.fetchNotes(inNotebook: id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
