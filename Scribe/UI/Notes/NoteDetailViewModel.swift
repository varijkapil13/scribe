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
    @Published var sessions: [Session] = []

    private let store: NoteStore
    private let transcriptStore: TranscriptStore
    private let onNavigate: (String) -> Void
    private var autosaveCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?

    init(
        note: Note,
        store: NoteStore = .shared,
        transcriptStore: TranscriptStore = .shared,
        onNavigate: @escaping (String) -> Void = { _ in }
    ) {
        self.note = note
        self.store = store
        self.transcriptStore = transcriptStore
        self.onNavigate = onNavigate
        reload()
        autosaveCancellable = $isDirty
            .filter { $0 }
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
        sessionsCancellable = transcriptStore
            .observeSessions(forNoteId: note.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] sessions in
                    self?.sessions = sessions
                }
            )
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
        onNavigate(target.id)
    }

    func markDirty() { isDirty = true }
}
