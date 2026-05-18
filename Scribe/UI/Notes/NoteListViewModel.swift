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
    @Published var errorMessage: String? = nil
    /// Set by `requestDelete(id:)`; the View observes it and shows a
    /// confirmation dialog. Cleared either by `confirmDelete(_:)` or by the
    /// View resetting it on cancel.
    @Published var pendingDelete: DeleteNoteRequest? = nil

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
    @discardableResult
    func confirmDelete(_ request: DeleteNoteRequest) -> String? {
        defer { pendingDelete = nil }
        do {
            try store.deleteNote(id: request.noteId)
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
