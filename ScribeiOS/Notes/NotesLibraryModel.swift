// ScribeiOS/Notes/NotesLibraryModel.swift
//
// Live data and actions for the iPhone / iPad notes browser: notes, notebooks
// and tags observed from the shared `NoteStore` (GRDB value observation), plus
// create / rename / move / delete and notebook management. The pure list rules
// (destinations, search, sort) are `NoteBrowserQuery` (Scribe/UI/Notes/
// Portable, unit-tested).

import Combine
import Foundation
import Observation

@MainActor
@Observable
final class NotesLibraryModel {

    private(set) var notes: [Note] = []
    private(set) var notebooks: [Notebook] = []
    private(set) var tags: [String] = []
    var errorMessage: String?

    let store: NoteStore
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var started = false

    init(store: NoteStore) {
        self.store = store
    }

    /// Subscribes to the store. Idempotent (call from `.task`/`onAppear`).
    func start() {
        guard !started else { return }
        started = true
        store.observeNotes()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] notes in
                self?.notes = notes
                self?.refreshTags()
            })
            .store(in: &cancellables)
        store.observeNotebooks()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] notebooks in
                self?.notebooks = notebooks
            })
            .store(in: &cancellables)
    }

    private func refreshTags() {
        let fresh = (try? store.allNoteTags()) ?? []
        if fresh != tags { tags = fresh }
    }

    // MARK: - Lists

    /// The notes `item` shows, filtered by `search` (full-text, with a
    /// substring fallback) and sorted.
    func notes(for item: NotesSidebarItem, search: String, sort: NoteSortOrder) -> [Note] {
        var tagMembers: Set<String>?
        if case .tag(let tag) = item {
            tagMembers = Set(((try? store.fetchNotes(withTag: tag)) ?? []).map(\.id))
        }
        var searchMatches: Set<String>?
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            var matches = Set(notes.filter { NoteBrowserQuery.matches($0, search: query) }.map(\.id))
            if let fts = try? store.searchNotes(query: query) {
                matches.formUnion(fts.map(\.id))
            }
            searchMatches = matches
        }
        return NoteBrowserQuery.notes(notes, for: item, tagMembers: tagMembers,
                                      searchMatches: searchMatches, sort: sort)
    }

    func count(for item: NotesSidebarItem) -> Int {
        if case .tag = item { return notes(for: item, search: "", sort: .updated).count }
        return notes.filter { NoteBrowserQuery.includes($0, in: item, tagMembers: nil) }.count
    }

    func notebookName(_ id: String?) -> String {
        guard let id else { return "Inbox" }
        return notebooks.first { $0.id == id }?.name ?? "Notebook"
    }

    /// Notebooks depth-first (children under their parent) with their depth.
    var notebookTree: [NotebookTreeEntry] {
        var children: [String?: [Notebook]] = [:]
        for notebook in notebooks { children[notebook.parentId, default: []].append(notebook) }
        let known = Set(notebooks.map(\.id))
        var out: [NotebookTreeEntry] = []
        var visited = Set<String>()
        func visit(_ parent: String?, depth: Int) {
            for notebook in children[parent] ?? [] where visited.insert(notebook.id).inserted {
                out.append(NotebookTreeEntry(notebook: notebook, depth: depth))
                visit(notebook.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        // Orphans (parent missing) at the top level.
        for notebook in notebooks where notebook.parentId.map({ !known.contains($0) }) == true
            && visited.insert(notebook.id).inserted {
            out.append(NotebookTreeEntry(notebook: notebook, depth: 0))
            visit(notebook.id, depth: 1)
        }
        return out
    }

    // MARK: - Notes

    /// Creates an empty note in `item`'s notebook / with its tag.
    func createNote(in item: NotesSidebarItem) -> String? {
        do {
            let tags = item.tagForNewNotes.map { [$0] } ?? []
            return try store.createNote(title: "", body: "", tags: tags,
                                        notebookId: item.notebookIdForNewNotes).id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Today's daily note (created when missing).
    func todaysDailyNoteId() -> String? {
        do {
            return try store.dailyNoteCreatingIfNeeded(for: Date()).note.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(noteId: String, to rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard var note = try store.fetchNote(id: noteId), note.title != title else { return }
            note.title = title
            try store.updateNote(note, tags: try store.tags(for: noteId))
            NotificationCenter.default.post(name: .noteVaultFilesChanged, object: nil,
                                            userInfo: [NoteVaultChange.noteIdsKey: Set([noteId])])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(noteId: String, toNotebookId notebookId: String?) {
        do {
            try store.moveNote(id: noteId, toNotebookId: notebookId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(noteId: String) {
        do {
            try store.deleteNote(id: noteId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Linked recordings deleted along with the note (shown in the prompt).
    func sessionCount(noteId: String) -> Int {
        (try? store.sessionCount(forNoteId: noteId)) ?? 0
    }

    // MARK: - Notebooks

    @discardableResult
    func createNotebook(named rawName: String, parentId: String? = nil) -> Notebook? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            return try store.createNotebook(name: name, parentId: parentId)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameNotebook(_ notebook: Notebook, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != notebook.name else { return }
        var updated = notebook
        updated.name = name
        do {
            try store.updateNotebook(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteNotebook(_ notebook: Notebook) {
        do {
            try store.deleteNotebook(id: notebook.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A notebook in the sidebar tree.
struct NotebookTreeEntry: Identifiable {
    let notebook: Notebook
    let depth: Int
    var id: String { notebook.id }
}
