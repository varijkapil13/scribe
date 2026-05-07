// Scribe/UI/Notes/NoteDetailViewModel.swift
import Foundation
import Combine

@MainActor
final class NoteDetailViewModel: ObservableObject {
    @Published var note: Note
    @Published var tags: [String] = []
    @Published var backlinks: [Note] = []
    @Published var isDirty: Bool = false
    @Published var errorMessage: String? = nil

    private let store: NoteStore
    var onNavigate: ((String) -> Void)?

    init(note: Note, store: NoteStore = .shared) {
        self.note = note
        self.store = store
        reload()
    }

    private func reload() {
        do {
            tags = try store.tags(for: note.id)
            backlinks = try store.backlinks(for: note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() {
        do {
            try store.updateNote(note, tags: tags)
            backlinks = (try? store.backlinks(for: note.id)) ?? []
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleWikiLinkNavigate(anchor: String) {
        guard let target = try? store.resolveTitle(anchor) else { return }
        onNavigate?(target.id)
    }

    func markDirty() { isDirty = true }
}
