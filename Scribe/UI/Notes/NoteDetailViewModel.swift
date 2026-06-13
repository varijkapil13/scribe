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
    /// Exposed for view-level features (e.g. Export) that need the same
    /// `TranscriptStore` instance the VM observes from, so DI is preserved
    /// end-to-end and tests can swap in an in-memory store.
    let transcriptStore: TranscriptStore
    private let taskStore: TaskStore
    private let onNavigate: (String) -> Void
    private var autosaveCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?

    /// Per-session TranscriptDetailViewModel cache, lazily populated. Reused
    /// across chip selections so analysis state survives expansion-collapse
    /// and NaturalLanguage analysis doesn't re-run on every chip click.
    /// Capped at 5 entries (LRU); the most-recently-used sessions stay warm.
    private var transcriptVMCache: [String: TranscriptDetailViewModel] = [:]

    init(
        note: Note,
        store: NoteStore = .shared,
        transcriptStore: TranscriptStore = .shared,
        taskStore: TaskStore = .shared,
        onNavigate: @escaping (String) -> Void = { _ in }
    ) {
        self.note = note
        self.store = store
        self.transcriptStore = transcriptStore
        self.taskStore = taskStore
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

    /// Flushes a pending autosave immediately. The autosave runs on a 1.5s
    /// debounce; when the note view goes away (switching notes, closing the
    /// window) the debounce timer is cancelled with the view model, so edits
    /// made inside that window would be lost. Call this on `.onDisappear` to
    /// commit them synchronously first.
    func flushPendingSave() {
        if isDirty { save() }
    }

    private static let transcriptVMCacheCap = 5
    private var transcriptVMCacheOrder: [String] = []

    /// Returns the (cached) TranscriptDetailViewModel for a session bound to
    /// this note. Lazily created on first request and reused across chip
    /// selections so analysis / summary state survives expansion-collapse and
    /// the NaturalLanguage analyser doesn't re-run on every chip click.
    /// The cache is capped at 5 entries (LRU); older sessions are evicted as
    /// newer ones are accessed.
    func transcriptDetailViewModel(for session: Session) -> TranscriptDetailViewModel {
        if let cached = transcriptVMCache[session.id] {
            // Bump to MRU.
            transcriptVMCacheOrder.removeAll { $0 == session.id }
            transcriptVMCacheOrder.append(session.id)
            return cached
        }
        let vm = TranscriptDetailViewModel(
            session: session,
            store: transcriptStore,
            taskStore: taskStore
        )
        transcriptVMCache[session.id] = vm
        transcriptVMCacheOrder.append(session.id)
        if transcriptVMCacheOrder.count > Self.transcriptVMCacheCap {
            let evicted = transcriptVMCacheOrder.removeFirst()
            transcriptVMCache.removeValue(forKey: evicted)
        }
        return vm
    }

    /// Starts a new recording bound to this note. Delegates to AppDelegate so
    /// that permission errors surface via the standard alert (with deep-links
    /// to System Settings) rather than the plain in-note error message.
    func startRecording(appDelegate: AppDelegate) {
        Task {
            await appDelegate.startRecording()
        }
    }
}
