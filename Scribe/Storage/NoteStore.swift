// Scribe/Storage/NoteStore.swift
import Foundation
import GRDB
import Combine

enum NoteStoreError: Error, LocalizedError {
    case dailyNoteNotFound(String)
    var errorDescription: String? {
        switch self {
        case .dailyNoteNotFound(let key): return "Daily note for \(key) not found after insert."
        }
    }
}

// @unchecked Sendable is safe: DatabaseQueue is thread-safe and dbManager is
// immutable after init — no mutable state crosses actor boundaries.
final class NoteStore: @unchecked Sendable {

    let dbManager: DatabaseManager
    /// Swappable backing storage. Mutated only via `setFileStore(_:)` from
    /// `VaultCoordinator` when the user moves or opens a different vault.
    /// Read access goes through the `fileStore` computed property so
    /// every caller sees a coherent snapshot — a hot-swap can happen
    /// between calls but never mid-call.
    private let fileStoreLock = NSLock()
    private var _fileStore: NoteFileStore?
    var fileStore: NoteFileStore? {
        fileStoreLock.lock()
        defer { fileStoreLock.unlock() }
        return _fileStore
    }

    /// Replaces the backing file store. Caller is responsible for any
    /// upstream coordination (stopping the watcher, reconciling, etc.) —
    /// this method just guards the swap.
    func setFileStore(_ newValue: NoteFileStore?) {
        fileStoreLock.lock()
        _fileStore = newValue
        fileStoreLock.unlock()
    }
    private var db: DatabaseQueue { dbManager.database }

    // nonisolated(unsafe) required for Swift 6 strict concurrency on a global
    // stored property accessed from non-isolated contexts.
    nonisolated static let shared: NoteStore = {
        let dir = try? NotesDirectory.defaultLocation()
        let fileStore = dir.map { NoteFileStore(directory: $0) }
        let store = NoteStore(databaseManager: .shared, fileStore: fileStore,
                              versionStore: NoteVersionStore.makeDefault(dbManager: .shared))
        // Settings › Templates › daily note template.
        store.setDailyNoteSeed { fileStore, date, title in
            NoteTemplateDefaults.dailyNoteBody(fileStore: fileStore, date: date, title: title)
        }
        return store
    }()

    /// `fileStore` is optional so logic-only tests can opt out of disk
    /// mirroring without touching real filesystem state. When non-nil,
    /// every successful DB write is mirrored to a `.md` file under
    /// `fileStore.directory.root`, and `fetchNote(id:)` prefers the
    /// disk body over the DB column when both exist.
    init(databaseManager: DatabaseManager = .shared, fileStore: NoteFileStore? = nil,
         versionStore: NoteVersionStore? = nil) {
        self.dbManager = databaseManager
        self._fileStore = fileStore
        self.versionStore = versionStore
    }

    /// Version history (snapshots of previous content before saves). nil in
    /// logic-only tests that don't opt in.
    let versionStore: NoteVersionStore?

    /// Supplies the initial body of a daily note this store creates (the
    /// Settings-chosen daily template): `(fileStore, date, title) -> body`.
    typealias DailyNoteSeed = @Sendable (NoteFileStore?, Date, String) -> String?
    private let seedLock = NSLock()
    private var _dailyNoteSeed: DailyNoteSeed?

    func setDailyNoteSeed(_ seed: DailyNoteSeed?) {
        seedLock.lock()
        _dailyNoteSeed = seed
        seedLock.unlock()
    }

    private var dailyNoteSeed: DailyNoteSeed? {
        seedLock.lock()
        defer { seedLock.unlock() }
        return _dailyNoteSeed
    }

    // MARK: - CRUD

    @discardableResult
    func createNote(title: String, body: String = "", tags: [String] = [],
                    isDailyNote: Bool = false, dailyDate: String? = nil,
                    notebookId: String? = nil) throws -> Note {
        let created = try db.write { database -> Note in
            var note = Note(title: title, body: body,
                            isDailyNote: isDailyNote, dailyDate: dailyDate,
                            notebookId: notebookId)
            note.bodyExcerpt = Note.makeExcerpt(from: body)
            try note.insert(database)
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }
            try Self.upsertFTS(database, noteId: note.id, title: title, body: body)
            // Mirror inside the transaction: the reconciler lists the vault
            // inside its own write transaction, so it can never observe the
            // row without the file (and delete it). A failed file write
            // rolls the row back.
            try mirrorToDisk(note: note, tags: tags)
            return note
        }
        return created
    }

    /// Saves `note` (DB row, tags, links, FTS and its `.md` file). Before the
    /// file is overwritten, its previous content is snapshotted into version
    /// history per `NoteVersionPolicy` (`versionReason` other than `.edit`
    /// bypasses the five-minute throttle).
    func updateNote(_ note: Note, tags: [String], versionReason: NoteVersionReason = .edit) throws {
        recordVersionBeforeSave(of: note, reason: versionReason)
        try db.write { database in
            var mutable = note
            mutable.updatedAt = Date()
            mutable.bodyExcerpt = Note.makeExcerpt(from: note.body)
            try mutable.update(database)

            // rewrite tags
            try database.execute(sql: "DELETE FROM note_tags WHERE noteId = ?",
                                 arguments: [note.id])
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }

            // rewrite wiki-links
            let anchors = Self.parseWikiLinks(from: mutable.body)
            try database.execute(sql: "DELETE FROM note_links WHERE sourceNoteId = ?",
                                 arguments: [note.id])
            for anchor in anchors {
                if let target = try Self.resolveLinkTarget(database, anchor: anchor) {
                    let link = NoteLinkRow(sourceNoteId: note.id,
                                          targetNoteId: target.id,
                                          anchorText: anchor)
                    // insertOrIgnore: duplicate (sourceNoteId, targetNoteId, anchorText)
                    // is expected when a note links to the same target twice with
                    // identical anchor text — silently skip the duplicate.
                    try link.insert(database, onConflict: .ignore)
                }
            }
            try Self.upsertFTS(database, noteId: note.id, title: mutable.title, body: note.body)
            // Inside the transaction — see `createNote`.
            try mirrorToDisk(note: mutable, tags: tags)
        }
    }

    func deleteNote(id: String) throws {
        let audioDirectories = try db.write { database -> [String] in
            // Collect retained-audio folders before the session rows go.
            let audioPaths = try String.fetchAll(
                database,
                sql: "SELECT audioDirectory FROM sessions WHERE noteId = ? AND audioDirectory IS NOT NULL",
                arguments: [id]
            )
            // Cascade-delete sessions owned by this note. The session's FKs
            // (set up in v1 and v2 migrations) cascade to segments,
            // meeting_summaries, action_items, and extracted_entities.
            // Tasks.sourceSessionId is ON DELETE SET NULL so converted tasks
            // survive with their source link cleared.
            try database.execute(
                sql: "DELETE FROM sessions WHERE noteId = ?",
                arguments: [id]
            )
            _ = try Note.deleteOne(database, key: id)
            try database.execute(sql: "DELETE FROM notes_fts WHERE noteId = ?", arguments: [id])
            // Inside the transaction so a concurrent reconcile can't see the
            // file without the row and resurrect the note.
            deleteFromDisk(id: id)
            return audioPaths
        }
        for path in audioDirectories {
            SessionAudioStorage.removeDirectory(atPath: path)
        }
        // Best-effort: remove the note's attachments folder. Failures are
        // logged but don't propagate — the DB row is already gone. Logging
        // the resolved directory path (under public privacy — it contains
        // only a UUID-based note id, never user content) makes it possible
        // to manually clean up an orphan directory if needed.
        do {
            try AttachmentsDirectory.cleanup(forNoteId: id)
        } catch {
            let dir = AttachmentsDirectory.defaultRoot()
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            Log.storage.error("Failed to clean attachments for note \(id, privacy: .public) at \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Re-creates a note removed by `deleteNote` (Edit › Undo Delete Note)
    /// under its original id, timestamps, notebook and tags, and writes its
    /// file back into the vault. Callers must only offer this for notes that
    /// had no recordings or attachments — `deleteNote` destroys those and
    /// they can't come back. `note.body` must hold the real body (from
    /// `fetchNote` before the delete). `extra` carries the file's other
    /// frontmatter keys (typed properties, `font:`, external tools' keys) —
    /// they live only on disk, so the caller snapshots them before the delete.
    /// Outgoing wiki-links are rebuilt here; links *into* the note are rebuilt
    /// as the linking notes are next saved.
    func restoreDeletedNote(_ note: Note, tags: [String], extra: [FrontmatterEntry] = []) throws {
        try db.write { database in
            var restored = note
            restored.bodyExcerpt = Note.makeExcerpt(from: note.body)
            // The notebook may have been deleted since; notebookId has no FK,
            // so drop a dangling reference rather than restore into nowhere.
            if let notebookId = restored.notebookId,
               try Notebook.fetchOne(database, key: notebookId) == nil {
                restored.notebookId = nil
            }
            try restored.insert(database)
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }
            for anchor in Self.parseWikiLinks(from: note.body) {
                if let target = try Self.resolveLinkTarget(database, anchor: anchor) {
                    let link = NoteLinkRow(sourceNoteId: note.id,
                                           targetNoteId: target.id,
                                           anchorText: anchor)
                    try link.insert(database, onConflict: .ignore)
                }
            }
            try Self.upsertFTS(database, noteId: note.id, title: note.title, body: note.body)
            // Inside the transaction — see `createNote`.
            try mirrorToDisk(note: restored, tags: tags, extra: extra)
        }
    }

    /// Returns the number of recording sessions bound to a note. Cheap —
    /// hits the `sessions_noteId_idx` index. Used by the UI to decide
    /// whether deleting a note needs an explicit confirmation about the
    /// destructive cascade (sessions + segments + summaries + entities).
    func sessionCount(forNoteId noteId: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM sessions WHERE noteId = ?",
                arguments: [noteId]
            ) ?? 0
        }
    }

    func fetchNote(id: String) throws -> Note? {
        guard var note = try db.read({ try Note.fetchOne($0, key: id) }) else { return nil }
        // Prefer the disk body when a file exists for this id — the file
        // is the source of truth for content; the DB column is a mirror
        // kept for FTS and migration purposes until Slice 5. Resolved
        // through the id → path index (one file read, no vault scan).
        if let fileStore, let entry = try? fileStore.locate(id: id) {
            note.body = entry.file.body
        }
        return note
    }

    // MARK: - External-edit support

    /// The note's file as it is on disk right now (parsed + fingerprint),
    /// or nil when there is no file store / no file for the id.
    func diskEntry(forNoteId id: String) -> NoteFileEntry? {
        guard let fileStore else { return nil }
        return try? fileStore.locate(id: id)
    }

    /// Current fingerprint of the note's file — one `stat` when `known`
    /// still matches, otherwise a read + hash.
    func currentFileFingerprint(forNoteId id: String, reusing known: NoteFileFingerprint?) -> NoteFileFingerprint? {
        fileStore?.fingerprint(forId: id, reusing: known)
    }

    /// Fingerprint of the version Scribe itself last wrote for the note.
    func lastWrittenFileFingerprint(forNoteId id: String) -> NoteFileFingerprint? {
        fileStore?.lastWrittenFingerprint(forId: id)
    }

    /// Scribe's last write for the note, provided it descends from `base`
    /// (the version an editor loaded) through Scribe's own writes only — so
    /// an in-app read-modify-write on top of an *external* edit (font,
    /// properties, notebook move) never makes that edit look like Scribe's.
    func ownWrittenFileFingerprint(forNoteId id: String, descendingFrom base: NoteFileFingerprint?) -> NoteFileFingerprint? {
        guard let base else { return nil }
        return fileStore?.lastWrittenFingerprint(forId: id, descendingFrom: base)
    }

    /// Preserves the current on-disk version of the note as a conflict copy
    /// next to it (fresh id, `(Scribe conflicted copy …)` name) before an
    /// in-app version overwrites it. Returns the copy's URL, or nil when
    /// there is no file to preserve.
    func preserveDiskVersionAsConflictCopy(noteId id: String) throws -> URL? {
        guard let fileStore, let entry = try fileStore.locate(id: id) else { return nil }
        return try fileStore.writeConflictCopy(of: entry)
    }

    func fetchAllNotes() throws -> [Note] {
        try db.read { try Note.order(Column("updatedAt").desc).fetchAll($0) }
    }

    // MARK: - Daily notes

    private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // Intentionally uses device timezone (no explicit timeZone set) so month/day
    // names appear in the user's locale and current timezone — unlike
    // dailyDateFormatter which uses en_US_POSIX for machine-readable keys.
    private static let dailyTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    /// Returns an existing daily note for `date`, or nil if none exists.
    /// Never creates a note — use `dailyNote(for:)` only when creation is
    /// explicitly intended (e.g. after the user starts typing).
    func fetchExistingDailyNote(for date: Date) throws -> Note? {
        let key = Self.dailyDateFormatter.string(from: date)
        guard let row = try db.read({ try Note.filter(sql: "dailyDate = ?", arguments: [key]).fetchOne($0) }) else {
            return nil
        }
        // The DB row's `body` is only a placeholder — load the real body
        // from disk, or an editor bound to this note would start empty and
        // overwrite the file on the first keystroke.
        return try fetchNote(id: row.id) ?? row
    }

    /// Atomically fetches or creates the daily note for `date`. Call only
    /// when creation is intended — for read-only lookup use fetchExistingDailyNote(for:).
    func dailyNote(for date: Date) throws -> Note {
        try dailyNoteCreatingIfNeeded(for: date).note
    }

    /// `dailyNote(for:)` that also reports whether this call created the
    /// note. Callers seeding content (the daily draft editor) must only
    /// write their text when `created` is true — otherwise the note already
    /// exists (another window, iCloud, an external editor) and its body must
    /// not be overwritten.
    func dailyNoteCreatingIfNeeded(for date: Date) throws -> (note: Note, created: Bool) {
        let key = Self.dailyDateFormatter.string(from: date)
        let title = "Daily Note \u{2013} \(Self.dailyTitleFormatter.string(from: date))"
        // Atomic: INSERT OR IGNORE then SELECT avoids TOCTOU race where two
        // rapid calls (e.g. double .onAppear) would create two notes for the
        // same date. The UNIQUE constraint on dailyDate enforces uniqueness at
        // the DB level; this write block makes the check-then-insert atomic.
        let (note, didCreate) = try db.write { database -> (Note, Bool) in
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO notes
                        (id, title, createdAt, updatedAt, isDailyNote, dailyDate)
                    VALUES (?, ?, ?, ?, 1, ?)
                    """,
                arguments: [UUID().uuidString, title, Date(), Date(), key]
            )
            // INSERT OR IGNORE is a no-op when today's note already exists;
            // `changesCount` tells us whether we actually created a row.
            let created = database.changesCount > 0
            guard let note = try Note.filter(sql: "dailyDate = ?", arguments: [key]).fetchOne(database) else {
                throw NoteStoreError.dailyNoteNotFound(key)
            }
            var result = note
            if created {
                // A new daily note starts from the Settings-chosen daily
                // template, if any; otherwise empty.
                let seed = dailyNoteSeed?(fileStore, date, title) ?? ""
                if !seed.isEmpty {
                    result.body = seed
                    result.bodyExcerpt = Note.makeExcerpt(from: seed)
                    try database.execute(sql: "UPDATE notes SET bodyExcerpt = ? WHERE id = ?",
                                         arguments: [result.bodyExcerpt, note.id])
                }
                try Self.upsertFTS(database, noteId: note.id, title: title, body: result.body)
                // Only mirror on actual creation. The fetched `note` carries an
                // empty body placeholder (bodies live on disk, not in the DB), so
                // mirroring an *existing* daily note would clobber its content.
                try mirrorToDisk(note: result, tags: [])
            }
            return (result, created)
        }
        return (note, didCreate)
    }

    /// Body the daily draft editor may write when it binds to `dailyNote`
    /// on the first keystroke. A freshly created note takes the draft; an
    /// existing note is never overwritten — its body is kept (nil = write
    /// nothing) unless it is still empty.
    nonisolated static func dailyDraftBodyToWrite(created: Bool, existingBody: String, draft: String) -> String? {
        if created { return draft }
        if existingBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return draft }
        return nil
    }

    func fetchNotes(withTag tag: String) throws -> [Note] {
        try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN note_tags ON notes.id = note_tags.noteId
                WHERE note_tags.tag = ?
                ORDER BY notes.updatedAt DESC
                """, arguments: [tag])
        }
    }

    func fetchDailyDates() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database,
                sql: "SELECT dailyDate FROM notes WHERE isDailyNote = 1 AND dailyDate IS NOT NULL ORDER BY dailyDate")
        }
    }

    // MARK: - Tags

    func tags(for noteId: String) throws -> [String] {
        try db.read { database in
            try NoteTagRow
                .filter(Column("noteId") == noteId)
                .fetchAll(database)
                .map(\.tag)
        }
    }

    func allNoteTags() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database, sql: "SELECT DISTINCT tag FROM note_tags ORDER BY tag")
        }
    }

    /// Titles of all notes. Used by the editor to style `[[wiki links]]` as
    /// resolved vs broken (matched case-insensitively, mirroring `resolveTitle`).
    func allNoteTitles() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database, sql: "SELECT title FROM notes")
        }
    }

    // MARK: - Links

    func fetchAllLinks() throws -> [NoteLinkRow] {
        try db.read { try NoteLinkRow.fetchAll($0) }
    }

    func backlinks(for noteId: String) throws -> [Note] {
        try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN note_links ON notes.id = note_links.sourceNoteId
                WHERE note_links.targetNoteId = ?
                ORDER BY notes.updatedAt DESC
                """, arguments: [noteId])
        }
    }

    // MARK: - Resolution

    func resolveTitle(_ title: String) throws -> Note? {
        try db.read { database in
            try Note.filter(sql: "LOWER(title) = LOWER(?)", arguments: [title]).fetchOne(database)
        }
    }

    // MARK: - Search

    func searchNotes(query: String) throws -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try fetchAllNotes() }
        let sanitized = Self.ftsQuery(from: q)
        guard !sanitized.isEmpty else { return [] }
        return try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN notes_fts ON notes.id = notes_fts.noteId
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts)
                LIMIT 100
                """, arguments: [sanitized])
        }
    }

    /// Thin wrapper kept for source-compatibility. Real logic lives in
    /// `FTSQuery.escape` so the same escaper is shared across notes, tasks,
    /// and the universal search transcripts pane.
    static func ftsQuery(from raw: String) -> String { FTSQuery.escape(raw) }

    // MARK: - Observation

    func observeNotes() -> AnyPublisher<[Note], Error> {
        ValueObservation
            .tracking { try Note.order(Column("updatedAt").desc).fetchAll($0) }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }

    func observeNotebooks() -> AnyPublisher<[Notebook], Error> {
        ValueObservation
            .tracking { try Notebook.order(Column("sortOrder")).fetchAll($0) }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }

    // MARK: - Notebooks

    @discardableResult
    func createNotebook(name: String, parentId: String? = nil) throws -> Notebook {
        try db.write { database in
            let maxSort = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM notebooks") ?? -1
            let nb = Notebook(name: name, sortOrder: maxSort + 1, parentId: parentId)
            try nb.insert(database)
            return nb
        }
    }

    func updateNotebook(_ notebook: Notebook) throws {
        try db.write { try notebook.update($0) }
    }

    func deleteNotebook(id: String) throws {
        try db.write { database in
            let affected = try String.fetchAll(
                database,
                sql: "SELECT id FROM notes WHERE notebookId = ?",
                arguments: [id]
            )
            try database.execute(
                sql: "UPDATE notes SET notebookId = NULL WHERE notebookId = ?",
                arguments: [id]
            )
            // The file's frontmatter is the source of truth the reconciler
            // restores from — rewrite it too, or the next pass would put
            // the notes straight back into the deleted notebook. A failure
            // rolls the whole delete back.
            for noteId in affected {
                try rewriteFrontmatter(noteId: noteId) { $0.notebookId = nil }
            }
            // Promote child notebooks to the parent level so they aren't orphaned.
            try database.execute(
                sql: "UPDATE notebooks SET parentId = NULL WHERE parentId = ?",
                arguments: [id]
            )
            try Notebook.deleteOne(database, key: id)
        }
    }

    func fetchAllNotebooks() throws -> [Notebook] {
        try db.read { try Notebook.order(Column("sortOrder")).fetchAll($0) }
    }

    // Notes filtered by notebook. nil = Inbox (notebookId IS NULL and not a daily note).
    func fetchNotes(inNotebook notebookId: String) throws -> [Note] {
        try db.read { database in
            try Note
                .filter(Column("notebookId") == notebookId)
                .order(Column("updatedAt").desc)
                .fetchAll(database)
        }
    }

    func fetchInboxNotes() throws -> [Note] {
        try db.read { database in
            try Note
                // GRDB maps `== nil` to `IS NULL` — intentional, selects unassigned notes.
                .filter(Column("notebookId") == nil && Column("isDailyNote") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(database)
        }
    }

    func moveNote(id: String, toNotebookId: String?) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE notes SET notebookId = ? WHERE id = ?",
                arguments: [toNotebookId, id]
            )
            // Keep the file's `notebookId` in step so the reconciler
            // doesn't restore the old notebook.
            try rewriteFrontmatter(noteId: id) { $0.notebookId = toNotebookId }
        }
    }

    /// Re-writes only the frontmatter of the note's file (body and every
    /// other key preserved). No-op when there's no file store / file.
    private func rewriteFrontmatter(noteId: String, _ change: (inout NoteFrontmatter) -> Void) throws {
        guard let fileStore, let entry = try fileStore.locate(id: noteId) else { return }
        var file = entry.file
        change(&file.frontmatter)
        guard file != entry.file else { return }
        try fileStore.write(file)
    }

    // MARK: - FTS (Phase 5 — Slice 5)

    /// Replaces the FTS row for `noteId`. The contentless `notes_fts`
    /// table has no triggers — every NoteStore write site and the
    /// reconciler call this directly so search stays in sync with the
    /// disk-side body.
    static func upsertFTS(_ db: Database, noteId: String, title: String, body: String) throws {
        try db.execute(sql: "DELETE FROM notes_fts WHERE noteId = ?", arguments: [noteId])
        try db.execute(
            sql: "INSERT INTO notes_fts(noteId, title, body) VALUES (?, ?, ?)",
            arguments: [noteId, title, body]
        )
    }

    // MARK: - Disk migration (Phase 5 — Slice 3)

    /// Mirrors every DB-resident note to disk that isn't already on disk.
    /// Idempotent: matching ids are skipped without rewriting the file,
    /// so a crash mid-flight leaves a clean resumable state — the next
    /// invocation picks up exactly where the previous one stopped.
    ///
    /// Returns the number of files written, for caller-side logging.
    /// Single-pass: builds the on-disk id set once, then walks the DB —
    /// avoids the O(N²) lookup that a per-note `findURL` scan would do.
    @discardableResult
    func migrateNotesToDisk() throws -> Int {
        guard let fileStore else { return 0 }
        let onDisk = Set((try fileStore.listAll()).map(\.id))
        let inDb = try db.read { try Note.fetchAll($0) }
        var written = 0
        for note in inDb where !onDisk.contains(note.id) {
            let tags = (try? self.tags(for: note.id)) ?? []
            // Tolerant: one unwritable note shouldn't abort the whole sweep.
            do {
                try mirrorToDisk(note: note, tags: tags)
                written += 1
            } catch {
                Log.storage.error("migrateNotesToDisk: skipped \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    // MARK: - Disk mirror (Phase 5 — Slice 2)

    /// Builds the on-disk representation of a note and writes it through
    /// `fileStore`. The `.md` file is the source of truth for the body (the
    /// `notes.body` column was dropped in v13 — SQLite keeps only a short
    /// `bodyExcerpt`), so a failed write here means the body is *lost*. The
    /// error is therefore propagated to the caller (which surfaces it to the
    /// user) rather than swallowed. Callers MUST pass a `note` whose `.body`
    /// holds the real body (e.g. from `fetchNote`), never a bare DB-decoded
    /// note whose `.body` is the empty placeholder.
    private func mirrorToDisk(note: Note, tags: [String], extra: [FrontmatterEntry]? = nil) throws {
        guard let fileStore else { return }
        // Preserve any unknown frontmatter keys already on disk (per-note
        // `font:`, external tools' `aliases:`/`cover:`, …). We rebuild the
        // typed fields from the DB, so without this merge a DB-driven write
        // would silently drop them. (`extra` overrides this for a restore,
        // when there is no file on disk to read them from.)
        let existingExtra: [FrontmatterEntry] = extra
            ?? (try? fileStore.locate(id: note.id))?.file.frontmatter.extra ?? []
        let file = NoteFile(
            id: note.id,
            frontmatter: NoteFrontmatter(
                title: note.title,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                notebookId: note.notebookId,
                tags: Self.normalizeTags(tags),
                isDailyNote: note.isDailyNote,
                dailyDate: note.dailyDate.flatMap(Self.parseDailyDate(_:)),
                extra: existingExtra
            ),
            body: note.body
        )
        // `NoteFileStore` records the written path + fingerprint with
        // `VaultWriteGuard`, so the watcher skips the reconcile this write
        // would otherwise trigger — the DB/index is already current.
        do {
            try fileStore.write(file)
        } catch {
            Log.storage.error("NoteStore.mirrorToDisk failed for \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Moves the disk mirror for `id` to the Trash (removes it where there
    /// is no Trash). Logging-only: orphaned files are recoverable via the
    /// rebuild path (Slice 4) so failures here don't propagate.
    private func deleteFromDisk(id: String) {
        guard let fileStore else { return }
        do {
            _ = try fileStore.delete(id: id)
        } catch {
            Log.storage.error("NoteStore.deleteFromDisk failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Per-note typeface (Obsidian-compatible frontmatter)

    /// Reads the per-note typeface from the file's `font:` frontmatter key.
    /// `nil` means "follow the app default".
    func noteFont(id: String) -> String? {
        guard let fileStore, let entry = try? fileStore.locate(id: id) else { return nil }
        return entry.file.frontmatter.extraValue(forKey: "font")
    }

    /// Persists the per-note typeface to frontmatter (nil clears it). Disk-only
    /// — `font` isn't a DB column, so the `.md` file stays the source of truth
    /// and the choice survives external edits / vault moves. Preserves body +
    /// other extras.
    func setNoteFont(id: String, _ font: String?) {
        guard let fileStore, let entry = try? fileStore.locate(id: id) else { return }
        var file = entry.file
        file.frontmatter.setExtra("font", font)
        do {
            try fileStore.write(file)
        } catch {
            Log.storage.error("NoteStore.setNoteFont failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Parses the YYYY-MM-DD daily-date string from the DB column into a
    /// Date for the frontmatter codec. Returns nil if the string is malformed.
    private static func parseDailyDate(_ s: String) -> Date? {
        dailyDateFormatter.date(from: s)
    }

    // MARK: - Private helpers

    static func normalizeTags(_ tags: [String]) -> [String] {
        // Deduplicate after normalising — matches TaskStore.normalisedTags behaviour.
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let wikiLinkRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)
    }()

    static func parseWikiLinks(from text: String) -> [String] {
        let regex = Self.wikiLinkRegex
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }
}
