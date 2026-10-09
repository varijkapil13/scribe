// Scribe/UI/People/PeopleViewModel.swift
import Foundation
import Combine

/// Drives the People surface: loads people aggregated across meetings,
/// filters them, and creates / refreshes person notes.
@MainActor
final class PeopleViewModel: ObservableObject {

    @Published private(set) var people: [Person] = []
    @Published var selectedId: String?
    @Published var filterText: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var selectedNoteId: String?
    @Published var errorMessage: String?

    private let dbManager: DatabaseManager
    private let noteService: PersonNoteService

    init(dbManager: DatabaseManager = .shared, noteStore: NoteStore = .shared) {
        self.dbManager = dbManager
        self.noteService = PersonNoteService(noteStore: noteStore)
    }

    var filteredPeople: [Person] {
        Self.filter(people, query: filterText)
    }

    var selectedPerson: Person? {
        guard let selectedId else { return nil }
        return people.first { $0.id == selectedId }
    }

    nonisolated static func filter(_ people: [Person], query: String) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return people }
        return people.filter { person in
            person.name.localizedCaseInsensitiveContains(q)
                || person.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    func load() async {
        isLoading = true
        let repository = PeopleRepository(dbManager: dbManager)
        let result: Result<[Person], Error> = await Task.detached(priority: .userInitiated) {
            Result { try repository.loadPeople() }
        }.value
        isLoading = false
        switch result {
        case .success(let loaded):
            people = loaded
            if selectedId == nil || !loaded.contains(where: { $0.id == selectedId }) {
                selectedId = loaded.first?.id
            }
            refreshSelectedNoteId()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func select(_ id: String?) {
        selectedId = id
        refreshSelectedNoteId()
    }

    func refreshSelectedNoteId() {
        guard let person = selectedPerson else {
            selectedNoteId = nil
            return
        }
        selectedNoteId = try? noteService.existingNoteId(for: person)
    }

    /// Creates the person note (or refreshes its auto block) and returns
    /// its id.
    @discardableResult
    func createOrRefreshNote(for person: Person) -> String? {
        do {
            let note = try noteService.createOrRefresh(person)
            selectedNoteId = note.id
            return note.id
        } catch {
            errorMessage = "Couldn't write the person note: \(error.localizedDescription)"
            return nil
        }
    }
}
