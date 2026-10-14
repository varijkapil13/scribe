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
    /// Sync-conflict copies of this note found in the vault (iCloud /
    /// Dropbox `(conflicted copy)` files, and the copies Scribe writes when
    /// an external edit races an unsaved in-app edit).
    @Published private(set) var conflicts: [NoteConflictDetector.Match] = []

    /// Fingerprint of the file version the editor content is based on
    /// (recorded on load, after every save, and on reload). Before writing,
    /// the file on disk is compared against it so an external edit is never
    /// overwritten blindly.
    private(set) var loadedFingerprint: NoteFileFingerprint?

    /// Locked-note state (NoteDetailViewModel+Locking.swift). While
    /// `.unlocked`, `note.body` is plaintext held in memory only and every
    /// save writes it sealed.
    @Published var lockPhase: LockedNotePhase = .notLocked
    let lockState = LockedNoteEditorState()

    let store: NoteStore
    /// Exposed for view-level features (e.g. Export) that need the same
    /// `TranscriptStore` instance the VM observes from, so DI is preserved
    /// end-to-end and tests can swap in an in-memory store.
    let transcriptStore: TranscriptStore
    private let taskStore: TaskStore
    private let onNavigate: (String) -> Void
    private var autosaveCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?
    private var vaultChangeCancellable: AnyCancellable?
    private var peerSaveCancellable: AnyCancellable?
    /// Another in-app editor of this note (the same note open in the main
    /// window and a note window) saved since this editor's content was
    /// loaded. Its write descends from our base, so the "Scribe wrote it"
    /// exemption must not apply: our next save keeps both versions instead of
    /// silently overwriting the other window's edits.
    private var peerSavedSinceLoad = false
    /// Bumped whenever a peer save arrives while edits are unsaved, so a save
    /// already in flight doesn't clear `peerSavedSinceLoad` for a later peer write.
    private var peerSaveCount = 0
    private struct PeerSave: Sendable {
        let sender: ObjectIdentifier?
        let noteId: String
    }
    private var inAppChangeCancellable: AnyCancellable?
    private var willChangeInAppCancellable: AnyCancellable?

    /// Per-session TranscriptDetailViewModel cache, lazily populated. Reused
    /// across chip selections so analysis state survives expansion-collapse
    /// and NaturalLanguage analysis doesn't re-run on every chip click.
    /// Capped at 5 entries (LRU); the most-recently-used sessions stay warm.
    private var transcriptVMCache: [String: TranscriptDetailViewModel] = [:]

    let writerId = UUID()
    private var saveGeneration = 0
    private var lastAppliedSaveGeneration = 0
    private var inFlightSave: (generation: Int, note: Note, tags: [String])?

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
        // The editor's base version and its fingerprint must describe the
        // same bytes: take the body from the file we fingerprint (callers
        // may hand in a DB row whose body is only a placeholder).
        if let entry = store.diskEntry(forNoteId: note.id) {
            self.note.body = entry.file.body
            loadedFingerprint = entry.fingerprint
        }
        reload()
        installLocking()
        refreshConflicts(announce: true)
        vaultChangeCancellable = NotificationCenter.default
            .publisher(for: .noteVaultFilesChanged)
            .map { NoteVaultChange.noteIds(from: $0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.handleExternalVaultChange(noteIds: ids)
            }
        peerSaveCancellable = NotificationCenter.default
            .publisher(for: .scribeNoteEditorDidSave)
            .compactMap { notification -> PeerSave? in
                guard let noteId = notification.userInfo?["noteId"] as? String else { return nil }
                let sender = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                return PeerSave(sender: sender, noteId: noteId)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] save in
                guard let self, save.sender != ObjectIdentifier(self), save.noteId == self.note.id else { return }
                self.handlePeerSave()
            }
        inAppChangeCancellable = NotificationCenter.default
            .publisher(for: .scribeNoteChangedInApp)
            .map { NoteVaultChange.noteIds(from: $0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.handleInAppChange(noteIds: ids)
            }
        // Delivered synchronously (no `receive(on:)`): a version restore or a
        // mention link is about to rewrite this note — save unsaved edits
        // first so the rewrite builds on them.
        willChangeInAppCancellable = NotificationCenter.default
            .publisher(for: .scribeNoteWillChangeInApp)
            .sink { [weak self] notification in
                guard let self else { return }
                if let ids = NoteVaultChange.noteIds(from: notification), !ids.contains(self.note.id) { return }
                self.flushPendingSave()
            }
        autosaveCancellable = $isDirty
            .filter { $0 }
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveInBackground() }
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
            loadProperties()
            refreshLinkState()
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
        store.modifyNote(id: note.id, by: .editor(writerId)) { writeProperties(updated) }
    }

    private func writeProperties(_ updated: [NoteProperty]) {
        guard let fileStore = store.fileStore,
              let entry = try? fileStore.locate(id: note.id) else {
            // No disk backing — keep the edit live in-memory so the UI still
            // reflects it, but there's nowhere to persist.
            properties = updated
            return
        }
        // This is a read-modify-write of the *current* file, so it never
        // drops an external body edit. Whether the editor is still in sync
        // with disk decides what happens to the editor afterwards.
        let lastOwn = lastOwnWrite()
        let wasInSync = NoteExternalEditPolicy.isUnchanged(loaded: loadedFingerprint, current: entry.fingerprint)
            || (lastOwn.map { entry.fingerprint.describesSameContent(as: $0) } ?? false)
        var file = entry.file
        file.frontmatter.applyProperties(updated)
        do {
            _ = try fileStore.write(file)
            // Re-derive from what was actually written so the bound list
            // matches disk (empty values dropped, order normalised).
            properties = file.frontmatter.properties()
            if wasInSync {
                loadedFingerprint = store.lastWrittenFileFingerprint(forNoteId: note.id)
            } else if !isDirty {
                // Disk had an external edit and the editor has nothing
                // unsaved: adopt the disk body we just wrote back.
                note.body = file.body
                adoptLoadedBodyForLocking()
                loadedFingerprint = store.lastWrittenFileFingerprint(forNoteId: note.id)
            }
            // else: unsaved in-app edits on top of a stale base — leave
            // `loadedFingerprint` stale so the next save keeps both versions.
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
        store.diskEntry(forNoteId: note.id)?.file.frontmatter
    }

    /// Saves synchronously, after any background save already queued.
    func save() {
        let request = makeSaveRequest()
        let outcome = Perf.measure("note.write.drain") {
            NoteWriteQueue.run { Self.performSave(request, store: store) }
        }
        applySave(outcome, for: request)
    }

    /// The autosave path: the external-edit check, DB write and file mirror
    /// run on `NoteWriteQueue`; the editor keeps its newer content and stays dirty
    /// if it changed while the write was in flight.
    func saveInBackground() {
        let request = makeSaveRequest()
        inFlightSave = (request.generation, request.editorNote, request.tags)
        let store = store
        NoteWriteQueue.async { [weak self] in
            let outcome = Self.performSave(request, store: store)
            Task { @MainActor [weak self] in
                guard let self else {
                    if case .saved = outcome {
                        NotificationCenter.default.post(name: .scribeNoteEditorDidSave, object: nil,
                                                        userInfo: ["noteId": request.noteId])
                    }
                    return
                }
                self.applySave(outcome, for: request)
            }
        }
    }

    private struct SaveRequest: Sendable {
        let generation: Int
        let editor: UUID
        let noteId: String
        let title: String
        let editorNote: Note
        let stored: Result<Note, SaveFailure>
        let tags: [String]
        let loaded: NoteFileFingerprint?
        let peerSavedSinceLoad: Bool
        let peerSaveCount: Int
        let hasUnsavedChanges: Bool
    }

    private struct SaveFailure: Error, Sendable {
        let message: String
    }

    private enum SaveOutcome: Sendable {
        case reloadFromDisk
        case failed(message: String)
        case saved(fingerprint: NoteFileFingerprint?, conflictCopyName: String?, changedInApp: Bool,
                   backlinks: [Note], titles: [String])
    }

    private func makeSaveRequest() -> SaveRequest {
        saveGeneration += 1
        var stored = note
        let storedResult: Result<Note, SaveFailure>
        do {
            // A locked note is written sealed; its plaintext never hits disk.
            stored.body = try bodyForStorage()
            storedResult = .success(stored)
        } catch {
            storedResult = .failure(SaveFailure(message: error.localizedDescription))
        }
        return SaveRequest(
            generation: saveGeneration,
            editor: writerId,
            noteId: note.id,
            title: note.title,
            editorNote: note,
            stored: storedResult,
            tags: tags,
            loaded: loadedFingerprint,
            peerSavedSinceLoad: peerSavedSinceLoad,
            peerSaveCount: peerSaveCount,
            hasUnsavedChanges: isDirty
        )
    }

    private nonisolated static func performSave(_ request: SaveRequest, store: NoteStore) -> SaveOutcome {
        store.modifyNote(id: request.noteId, by: .editor(request.editor)) {
            Perf.measure("NoteDetailViewModel.save") { writeSave(request, store: store) }
        }
    }

    private nonisolated static func writeSave(_ request: SaveRequest, store: NoteStore) -> SaveOutcome {
        var conflictCopyName: String?
        // A write by another editor or in-app writer that landed after
        // this request was built is not one this content includes.
        let changedInApp = request.peerSavedSinceLoad
            || request.loaded.map {
                NoteWriteQueue.hasForeignWrite(noteId: request.noteId, since: $0, editor: request.editor)
            } ?? false
        // Never overwrite an external edit blindly: compare the file on disk
        // with the version this editor was loaded from.
        if let loaded = request.loaded {
            let current = store.currentFileFingerprint(forNoteId: request.noteId, reusing: loaded)
            let lastOwn = changedInApp
                ? nil
                : store.ownWrittenFileFingerprint(forNoteId: request.noteId, descendingFrom: loaded)
            switch NoteExternalEditPolicy.decide(
                loaded: loaded,
                current: current,
                lastWrittenByScribe: lastOwn,
                hasUnsavedChanges: request.hasUnsavedChanges
            ) {
            case .write:
                break
            case .reloadFromDisk:
                return .reloadFromDisk
            case .keepBoth:
                do {
                    if let copy = try store.preserveDiskVersionAsConflictCopy(noteId: request.noteId) {
                        conflictCopyName = copy.deletingPathExtension().lastPathComponent
                    }
                } catch {
                    // Couldn't preserve the external version — don't destroy it.
                    return .failed(message: "\u{201C}\(request.title)\u{201D} was changed outside Scribe and couldn't be saved without losing that change: \(error.localizedDescription)")
                }
            }
        }
        do {
            // Overwriting an external edit (kept as a conflict copy) always
            // snapshots the disk version first; ordinary saves are throttled.
            let stored = try request.stored.get()
            try store.updateNote(stored, tags: request.tags,
                                 versionReason: conflictCopyName != nil ? .externalChange : .edit)
            return .saved(
                fingerprint: store.lastWrittenFileFingerprint(forNoteId: request.noteId),
                conflictCopyName: conflictCopyName,
                changedInApp: changedInApp,
                backlinks: (try? store.backlinks(for: request.noteId)) ?? [],
                titles: (try? store.allNoteTitles()) ?? []
            )
        } catch let failure as SaveFailure {
            return .failed(message: failure.message)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func applySave(_ outcome: SaveOutcome, for request: SaveRequest) {
        if inFlightSave?.generation == request.generation { inFlightSave = nil }
        // A later save already applied (or a different note is loaded): its
        // state supersedes this one.
        guard request.generation > lastAppliedSaveGeneration, request.noteId == note.id else { return }
        lastAppliedSaveGeneration = request.generation
        switch outcome {
        case .reloadFromDisk:
            snapshotBeforeAdoptingExternalChange()
            reloadFromDisk()
        case .failed(let message):
            errorMessage = message
        case let .saved(fingerprint, conflictCopyName, changedInApp, savedBacklinks, titles):
            if let conflictCopyName {
                let changedBy = changedInApp ? "elsewhere in Scribe" : "outside Scribe"
                errorMessage = "\u{201C}\(request.title)\u{201D} was changed \(changedBy) while you were editing. "
                    + "Your version was saved; the other version was kept as "
                    + "\u{201C}\(conflictCopyName)\u{201D}."
            }
            loadedFingerprint = fingerprint ?? loadedFingerprint
            peerSavedSinceLoad = peerSaveCount != request.peerSaveCount
            backlinks = savedBacklinks
            unresolvedLinkCount = Self.unresolvedLinkCount(body: note.body, titles: titles)
            if note == request.editorNote && tags == request.tags {
                isDirty = false
            }
            NotificationCenter.default.post(name: .scribeNoteEditorDidSave, object: self,
                                            userInfo: ["noteId": note.id])
            if conflictCopyName != nil {
                refreshConflicts(announce: false)
            }
        }
    }

    // MARK: - External edits

    /// Called when the vault watcher reconciled changes. `noteIds` nil means
    /// "unknown — check". With unsaved edits nothing happens here: the next
    /// save detects the change and keeps both versions.
    private func handleExternalVaultChange(noteIds: Set<String>?) {
        if let noteIds, !noteIds.contains(note.id) { return }
        guard !isDirty, let loaded = loadedFingerprint else { return }
        let current = store.currentFileFingerprint(forNoteId: note.id, reusing: loaded)
        let decision = NoteExternalEditPolicy.decide(
            loaded: loaded,
            current: current,
            lastWrittenByScribe: lastOwnWrite(),
            hasUnsavedChanges: false
        )
        if decision == .reloadFromDisk {
            snapshotBeforeAdoptingExternalChange()
            reloadFromDisk()
        }
    }

    /// Keeps the editor's current content in version history before an
    /// external change replaces it.
    private func snapshotBeforeAdoptingExternalChange() {
        store.snapshotVersion(noteId: note.id, title: note.title, body: note.body, reason: .externalChange)
    }

    /// Another editor of this note saved. Without unsaved edits, adopt its
    /// version now; with them, remember it so the next save keeps both.
    private func handlePeerSave() {
        if isDirty {
            peerSavedSinceLoad = true
            peerSaveCount += 1
        } else {
            reloadFromDisk()
        }
    }

    /// Another part of Scribe (Quick Capture appending to the daily note)
    /// rewrote this note's file. Treated like a peer editor's save: adopt it
    /// now, or, with unsaved edits, keep both versions on the next save.
    private func handleInAppChange(noteIds: Set<String>?) {
        if let noteIds, !noteIds.contains(note.id) { return }
        handlePeerSave()
    }

    /// The last version Scribe itself wrote on top of the loaded base — nil
    /// once another in-app editor of this note has saved (that write is not
    /// one this editor's content includes).
    private func lastOwnWrite() -> NoteFileFingerprint? {
        guard !peerSavedSinceLoad else { return nil }
        return store.ownWrittenFileFingerprint(forNoteId: note.id, descendingFrom: loadedFingerprint)
    }

    /// Replaces the editor content with the file as it is on disk now.
    private func reloadFromDisk() {
        guard let entry = store.diskEntry(forNoteId: note.id) else { return }
        let file = entry.file
        note.body = file.body
        adoptLoadedBodyForLocking()
        note.title = file.frontmatter.title
        note.notebookId = file.frontmatter.notebookId
        note.updatedAt = file.frontmatter.updatedAt
        tags = NoteStore.normalizeTags(file.frontmatter.tags)
        properties = file.frontmatter.properties()
        loadedFingerprint = entry.fingerprint
        peerSavedSinceLoad = false
        isDirty = false
        refreshLinkState()
    }

    /// Looks up conflict copies of this note off the main actor (the
    /// detector walks the vault) and publishes them. With `announce`, a
    /// non-empty result is reported through the banner once.
    private func refreshConflicts(announce: Bool) {
        guard let fileStore = store.fileStore else { return }
        let noteId = note.id
        let originalName = store.diskEntry(forNoteId: noteId)?.url.deletingPathExtension().lastPathComponent
        Task { [weak self] in
            let found: [NoteConflictDetector.Match] = await Task.detached(priority: .utility) {
                (try? NoteConflictDetector(fileStore: fileStore)
                    .conflicts(forNoteId: noteId, originalName: originalName)) ?? []
            }.value
            guard let self, self.note.id == noteId else { return }
            self.conflicts = found
            if announce, let first = found.first {
                self.errorMessage = found.count == 1
                    ? "This note has a conflicting copy: \u{201C}\(first.displayName)\u{201D}."
                    : "This note has \(found.count) conflicting copies, e.g. \u{201C}\(first.displayName)\u{201D}."
            }
        }
    }

    /// Refreshes `backlinks` and `unresolvedLinkCount` off the main actor.
    /// Called on load and reload; a save computes both on `NoteWriteQueue`.
    private func refreshLinkState() {
        let store = store
        let noteId = note.id
        Task { [weak self] in
            let (backlinks, titles) = await Task.detached(priority: .userInitiated) {
                Perf.measure("NoteDetailViewModel.refreshLinkState") {
                    (((try? store.backlinks(for: noteId)) ?? []), ((try? store.allNoteTitles()) ?? []))
                }
            }.value
            guard let self, self.note.id == noteId else { return }
            self.backlinks = backlinks
            self.unresolvedLinkCount = Self.unresolvedLinkCount(body: self.note.body, titles: titles)
        }
    }

    private static func unresolvedLinkCount(body: String, titles: [String]) -> Int {
        WikiLinkResolver.unresolvedAnchors(existingTitles: titles, body: body).count
    }

    /// Follows a clicked `[[link]]`, including `[[Note#Heading]]`,
    /// `[[Note#^block]]` and same-note `[[#Heading]]` links (which scroll the
    /// editor to the heading / block).
    func handleWikiLinkNavigate(anchor: String) {
        let parsed = WikiLinkTarget.parse(anchor)
        if parsed.refersToSameNote {
            if let line = NoteBlockReference.lineIndex(for: parsed, in: note.body) {
                WebEditorCommandCenter.shared.send(.scrollToLine(line + 1))
            }
            return
        }
        guard let resolved = try? store.resolveLinkTarget(anchor: anchor) else { return }
        let target = NoteEmbedExpander.effectiveTarget(parsed, anchor: anchor, resolvedTitle: resolved.title)
        if resolved.id == note.id {
            if let line = NoteBlockReference.lineIndex(for: target, in: note.body) {
                WebEditorCommandCenter.shared.send(.scrollToLine(line + 1))
            }
            return
        }
        onNavigate(resolved.id)
        if target.hasFragment,
           let body = (try? store.fetchNote(id: resolved.id))?.body,
           let line = NoteBlockReference.lineIndex(for: target, in: body) {
            NoteEditorDeferredScroll.scroll(toLine: line + 1)
        }
    }

    func markDirty() { isDirty = true }

    /// Re-bases the editor on Scribe's own latest write of this note (after
    /// a frontmatter-only write such as the locked-note flag).
    func rebaseOnOwnLatestWrite() {
        loadedFingerprint = store.lastWrittenFileFingerprint(forNoteId: note.id) ?? loadedFingerprint
    }

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
        guard isDirty else { return }
        if let inFlightSave, inFlightSave.note == note, inFlightSave.tags == tags {
            // The queued background save already holds this content; wait for
            // it to land instead of writing it twice.
            NoteWriteQueue.drain()
            return
        }
        save()
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
