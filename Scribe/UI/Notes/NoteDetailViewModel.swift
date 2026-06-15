// Scribe/UI/Notes/NoteDetailViewModel.swift
import Foundation
import Combine

@MainActor
final class NoteDetailViewModel: ObservableObject {
    @Published var note: Note
    @Published var tags: [String] = []
    @Published var backlinks: [Note] = []
    /// The note's typed frontmatter properties (Obsidian-style "properties"
    /// block), derived from the `.md` file's frontmatter `extra` on load and
    /// persisted straight back to disk on edit. Bound into `NotePropertiesView`
    /// in the editor header.
    @Published var properties: [NoteProperty] = []
    @Published var isDirty: Bool = false
    @Published var errorMessage: String? = nil
    @Published var sessions: [Session] = []
    /// Number of `[[wiki links]]` in the body that don't resolve to an existing
    /// note title. Recomputed on load and on save (not per keystroke) so the
    /// editor can surface a subtle "broken link" indicator.
    @Published var unresolvedLinkCount: Int = 0

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
            loadProperties()
            recomputeUnresolvedLinks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Properties (frontmatter)

    /// Reads the note's typed properties from its `.md` frontmatter `extra`
    /// map via the `NoteFrontmatter` bridge. Disk is the source of truth for
    /// frontmatter extras (they aren't DB columns), so we read straight from
    /// the file store. No-op when no file store is wired (logic-only tests
    /// without a disk mirror) — `properties` stays empty.
    func loadProperties() {
        guard let frontmatter = currentFrontmatter() else {
            properties = []
            return
        }
        properties = frontmatter.properties()
    }

    /// Persists the full property list back into the note's frontmatter,
    /// preserving the body and every other (reserved + unknown) frontmatter
    /// key, then refreshes the in-memory list to reflect the normalised /
    /// dropped-empty result. Called from `NotePropertiesView`'s `onCommit`.
    ///
    /// Properties are written directly to disk (not through `updateNote`)
    /// because frontmatter `extra` isn't mirrored from the DB — and
    /// `NoteStore.mirrorToDisk` already re-reads and preserves on-disk extras
    /// on a body/tag save, so the two write paths don't clobber each other.
    func updateProperties(_ updated: [NoteProperty]) {
        guard let fileStore = store.fileStore,
              let url = try? fileStore.findURL(for: note.id),
              var file = try? fileStore.read(at: url) else {
            // No disk backing — keep the edit live in-memory so the UI still
            // reflects it, but there's nowhere to persist.
            properties = updated
            return
        }
        file.frontmatter.applyProperties(updated)
        do {
            VaultWriteGuard.shared.recordSelfWrite()
            _ = try fileStore.write(file)
            // Re-derive from what was actually written so the bound list
            // matches disk (empty values dropped, order normalised).
            properties = file.frontmatter.properties()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Distinct existing values per `select`/`list` key across the note's own
    /// properties, powering `NotePropertiesView`'s suggestion menus.
    var propertyOptionSuggestions: [String: [String]] {
        var out: [String: [String]] = [:]
        for property in properties {
            switch property.value {
            case .select(let s) where !s.isEmpty:
                out[property.key, default: []].append(s)
            case .list(let xs):
                out[property.key, default: []].append(contentsOf: xs)
            default:
                break
            }
        }
        return out.mapValues { Array(Set($0)).sorted() }
    }

    /// The current on-disk frontmatter for this note, if a file store is wired
    /// and a file exists. Used to read/seed typed properties.
    private func currentFrontmatter() -> NoteFrontmatter? {
        guard let fileStore = store.fileStore,
              let url = try? fileStore.findURL(for: note.id),
              let file = try? fileStore.read(at: url) else { return nil }
        return file.frontmatter
    }

    func save() {
        do {
            try store.updateNote(note, tags: tags)
            backlinks = (try? store.backlinks(for: note.id)) ?? []
            recomputeUnresolvedLinks()
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recomputes `unresolvedLinkCount` from the current body against all
    /// existing note titles. Called on load and on save (cheap there, not on
    /// every keystroke).
    private func recomputeUnresolvedLinks() {
        let titles = ((try? store.fetchAllNotes()) ?? []).map(\.title)
        unresolvedLinkCount = WikiLinkResolver.unresolvedAnchors(
            existingTitles: titles,
            body: note.body
        ).count
    }

    func handleWikiLinkNavigate(anchor: String) {
        guard let target = try? store.resolveTitle(anchor) else { return }
        onNavigate(target.id)
    }

    func markDirty() { isDirty = true }

    // MARK: - Tags

    /// Suggestions for the inline tag token field: known note tags matching
    /// `prefix` (prefix hits first, then substring), excluding already-applied
    /// ones. Mirrors the Tasks inspector's autocomplete behaviour.
    func tagSuggestions(_ prefix: String) -> [String] {
        let applied = Set(tags)
        let pool = ((try? store.allNoteTags()) ?? []).filter { !applied.contains($0) }
        let q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pool }
        let prefixHits = pool.filter { $0.hasPrefix(q) }
        let substringHits = pool.filter { !$0.hasPrefix(q) && $0.contains(q) }
        return prefixHits + substringHits
    }

    /// Adds a normalised tag (trimmed, leading '#' stripped, lowercased — to
    /// match `NoteStore.normalizeTags` so the live chips equal what's saved).
    /// No-op for blanks or duplicates. Marks dirty so autosave persists it.
    func addTag(_ raw: String) {
        let normalised = Self.normalizeTag(raw)
        guard !normalised.isEmpty, !tags.contains(normalised) else { return }
        tags.append(normalised)
        markDirty()
    }

    func removeTag(_ tag: String) {
        guard let idx = tags.firstIndex(of: tag) else { return }
        tags.remove(at: idx)
        markDirty()
    }

    private static func normalizeTag(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

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
