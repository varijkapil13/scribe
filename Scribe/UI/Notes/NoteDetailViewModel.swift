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

    /// Per-session TranscriptDetailViewModel cache, lazily populated. Reused
    /// across chip selections so analysis state survives expansion-collapse
    /// and NaturalLanguage analysis doesn't re-run on every chip click.
    ///
    /// Note: the inner TranscriptDetailViewModel uses its default
    /// `TranscriptStore()` / `TaskStore()` (both backed by
    /// `DatabaseManager.shared`). Tests that exercise the auto-section will
    /// hit the on-disk DB. Full DI through the inner VM is a separate change.
    private var transcriptVMCache: [String: TranscriptDetailViewModel] = [:]

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

    /// Returns the (cached) TranscriptDetailViewModel for a session bound to
    /// this note. Lazily created on first request and reused across chip
    /// selections so analysis / summary state survives expansion-collapse and
    /// the NaturalLanguage analyser doesn't re-run on every chip click.
    func transcriptDetailViewModel(for session: Session) -> TranscriptDetailViewModel {
        if let cached = transcriptVMCache[session.id] {
            return cached
        }
        let vm = TranscriptDetailViewModel(session: session)
        transcriptVMCache[session.id] = vm
        return vm
    }

    /// Starts a new recording bound to this note. The detail pane will switch
    /// into live-recording mode automatically once AppState publishes
    /// `isTranscribing = true` and our `sessions` observation picks up the
    /// new chip.
    func startRecording(appState: AppState) {
        let title = note.title.isEmpty ? "Recording" : note.title
        Task { [weak self, noteId = note.id] in
            do {
                try await appState.startSession(title: title, noteId: noteId)
            } catch {
                await MainActor.run {
                    self?.errorMessage = "Couldn't start recording: \(error.localizedDescription)"
                }
            }
        }
    }
}
