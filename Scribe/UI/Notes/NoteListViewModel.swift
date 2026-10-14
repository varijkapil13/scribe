// Scribe/UI/Notes/NoteListViewModel.swift
import Foundation
import Combine

enum NoteListScope {
    case all
    case inbox
    case notebook(String)
}

/// One-shot request emitted when the user picks "Delete Note" on a row.
/// The View consumes it to render a confirmation dialog that surfaces the
/// destructive cascade (linked recordings → segments → summaries → entities)
/// before the deletion is allowed to proceed. Identifiable so SwiftUI's
/// `.confirmationDialog(item:)` can drive it.
struct DeleteNoteRequest: Identifiable, Equatable {
    var id: String { noteId }
    let noteId: String
    let noteTitle: String
    let sessionCount: Int
}

@MainActor
final class NoteListViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var searchText: String = ""
    /// `notes`, or the search results for `searchText`; recomputed off the
    /// main actor when either changes.
    @Published private(set) var filteredNotes: [Note] = []
    /// False until the first observation value arrives, so the view doesn't
    /// flash its empty state.
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String? = nil
    /// Set by `requestDelete(id:)`; the View observes it and shows a
    /// confirmation dialog. Cleared either by `confirmDelete(_:)` or by the
    /// View resetting it on cancel.
    @Published var pendingDelete: DeleteNoteRequest? = nil

    private let store: NoteStore
    private var cancellables = Set<AnyCancellable>()
    private var allNotes: [Note] = []
    private var searchTask: Task<Void, Never>?
    private var notebookNames: [String: String] = [:]
    var scope: NoteListScope = .all {
        didSet {
            title = scopeTitle()
            applyScope()
        }
    }
    /// Header title for the current scope.
    @Published private(set) var title = "All Notes"

    init(store: NoteStore = .shared, scope: NoteListScope = .all) {
        self.store = store
        self.scope = scope
        self.title = scopeTitle()
        store.observeNotebooks()
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] notebooks in
                      guard let self else { return }
                      self.notebookNames = Dictionary(notebooks.map { ($0.id, $0.name) },
                                                      uniquingKeysWith: { first, _ in first })
                      let title = self.scopeTitle()
                      if title != self.title { self.title = title }
                  })
            .store(in: &cancellables)
        store.observeNotes()
            .sink(receiveCompletion: { [weak self] completion in
                      if case .failure(let error) = completion {
                          self?.errorMessage = error.localizedDescription
                      }
                  },
                  receiveValue: { [weak self] all in
                      self?.allNotes = all
                      self?.hasLoaded = true
                      self?.applyScope()
                  })
            .store(in: &cancellables)
        // `$searchText` fires before the property changes, so the query is
        // taken from the emitted value. Clearing the field shows all notes at
        // once; typing is debounced.
        let query = $searchText
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .removeDuplicates()
        query.filter(\.isEmpty)
            .sink { [weak self] q in self?.refreshFilter(query: q) }
            .store(in: &cancellables)
        query.filter { !$0.isEmpty }
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.refreshFilter(query: q) }
            .store(in: &cancellables)
    }

    private func applyScope() {
        notes = switch scope {
        case .all:
            allNotes
        case .inbox:
            allNotes.filter { $0.notebookId == nil && !$0.isDailyNote }
        case .notebook(let id):
            allNotes.filter { $0.notebookId == id }
        }
        refreshFilter(query: searchText.trimmingCharacters(in: .whitespaces))
    }

    private func refreshFilter(query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            filteredNotes = notes
            return
        }
        guard query == searchText.trimmingCharacters(in: .whitespaces) else { return }
        let store = store
        searchTask = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                try? store.searchNotes(query: query)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.filteredNotes = results ?? self.notes
        }
    }

    private func scopeTitle() -> String {
        switch scope {
        case .all:   return "All Notes"
        case .inbox: return "Unfiled"
        case .notebook(let id):
            return notebookNames[id] ?? "Notebook"
        }
    }

    func createNote() -> Note? {
        let notebookId: String?
        if case .notebook(let id) = scope { notebookId = id } else { notebookId = nil }
        return try? store.createNote(title: "", body: "", tags: [], notebookId: notebookId)
    }

    /// Stages a deletion: looks up the note + bound-session count so the
    /// View can show "X linked recording(s) will also be deleted" in the
    /// confirmation. If the lookup fails (note already gone) the request is
    /// suppressed and the View won't show a dialog.
    func requestDelete(id: String) {
        guard let note = try? store.fetchNote(id: id) else { return }
        let count = (try? store.sessionCount(forNoteId: id)) ?? 0
        pendingDelete = DeleteNoteRequest(
            noteId: id,
            noteTitle: note.title,
            sessionCount: count
        )
    }

    /// Performs the actual delete the user just confirmed. Returns the
    /// noteId so the caller can clear any selection that was pointing at it.
    /// Pass the window's `undoManager` to make the delete undoable (when it
    /// safely can be — see `NoteUndo`).
    @discardableResult
    func confirmDelete(_ request: DeleteNoteRequest, undoManager: UndoManager? = nil) -> String? {
        defer { pendingDelete = nil }
        do {
            try NoteUndo.deleteNote(id: request.noteId, store: store, undoManager: undoManager)
            return request.noteId
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Deprecated direct deletion — only kept so any external callers don't
    /// silently lose their delete. New UI paths must go through
    /// `requestDelete(id:)` → `confirmDelete(_:)` so the cascade is gated.
    @available(*, deprecated, message: "Use requestDelete(id:) so the user is asked about the recording cascade.")
    func deleteNote(id: String) {
        do { try store.deleteNote(id: id) }
        catch { errorMessage = error.localizedDescription }
    }
}
