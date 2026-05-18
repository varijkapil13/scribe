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
    nonisolated(unsafe) static let shared: NoteStore = {
        let dir = try? NotesDirectory.defaultLocation()
        let fileStore = dir.map { NoteFileStore(directory: $0) }
        return NoteStore(databaseManager: .shared, fileStore: fileStore)
    }()

    /// `fileStore` is optional so logic-only tests can opt out of disk
    /// mirroring without touching real filesystem state. When non-nil,
    /// every successful DB write is mirrored to a `.md` file under
    /// `fileStore.directory.root`, and `fetchNote(id:)` prefers the
    /// disk body over the DB column when both exist.
    init(databaseManager: DatabaseManager = .shared, fileStore: NoteFileStore? = nil) {
        self.dbManager = databaseManager
        self._fileStore = fileStore
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
            return note
        }
        mirrorToDisk(note: created, tags: tags)
        return created
    }

    func updateNote(_ note: Note, tags: [String]) throws {
        let mirrored = try db.write { database -> Note in
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
                if let target = try Note
                    .filter(sql: "LOWER(title) = LOWER(?)", arguments: [anchor])
                    .fetchOne(database) {
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
            return mutable
        }
        mirrorToDisk(note: mirrored, tags: tags)
    }

    func deleteNote(id: String) throws {
        try db.write { database in
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
        }
        deleteFromDisk(id: id)
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
        // kept for FTS and migration purposes until Slice 5.
        if let fileStore,
           let url = try? fileStore.findURL(for: id),
           let parsed = try? fileStore.read(at: url) {
            note.body = parsed.body
        }
        return note
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
        return try db.read { try Note.filter(sql: "dailyDate = ?", arguments: [key]).fetchOne($0) }
    }

    /// Atomically fetches or creates the daily note for `date`. Call only
    /// when creation is intended — for read-only lookup use fetchExistingDailyNote(for:).
    func dailyNote(for date: Date) throws -> Note {
        let key = Self.dailyDateFormatter.string(from: date)
        let title = "Daily Note \u{2013} \(Self.dailyTitleFormatter.string(from: date))"
        // Atomic: INSERT OR IGNORE then SELECT avoids TOCTOU race where two
        // rapid calls (e.g. double .onAppear) would create two notes for the
        // same date. The UNIQUE constraint on dailyDate enforces uniqueness at
        // the DB level; this write block makes the check-then-insert atomic.
        let note = try db.write { database -> Note in
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO notes
                        (id, title, createdAt, updatedAt, isDailyNote, dailyDate)
                    VALUES (?, ?, ?, ?, 1, ?)
                    """,
                arguments: [UUID().uuidString, title, Date(), Date(), key]
            )
            guard let note = try Note.filter(sql: "dailyDate = ?", arguments: [key]).fetchOne(database) else {
                throw NoteStoreError.dailyNoteNotFound(key)
            }
            // Seed FTS for the new daily note with the title only — body
            // is empty at creation time.
            try Self.upsertFTS(database, noteId: note.id, title: title, body: "")
            return note
        }
        mirrorToDisk(note: note, tags: [])
        return note
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
            try database.execute(
                sql: "UPDATE notes SET notebookId = NULL WHERE notebookId = ?",
                arguments: [id]
            )
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
        }
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
            mirrorToDisk(note: note, tags: tags)
            written += 1
        }
        return written
    }

    // MARK: - Disk mirror (Phase 5 — Slice 2)

    /// Builds the on-disk representation of a note and writes it through
    /// `fileStore`. Failures are logged but never thrown — Slice 2 keeps
    /// SQLite as the source of truth, so a transient disk error must not
    /// roll back a successful DB write. Slice 4 will flip the polarity.
    private func mirrorToDisk(note: Note, tags: [String]) {
        guard let fileStore else { return }
        let file = NoteFile(
            id: note.id,
            frontmatter: NoteFrontmatter(
                title: note.title,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                notebookId: note.notebookId,
                tags: Self.normalizeTags(tags),
                isDailyNote: note.isDailyNote,
                dailyDate: note.dailyDate.flatMap(Self.parseDailyDate(_:))
            ),
            body: note.body
        )
        do {
            try fileStore.write(file)
        } catch {
            Log.storage.error("NoteStore.mirrorToDisk failed for \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the disk mirror for `id`. Same logging-only policy as
    /// `mirrorToDisk` — orphaned files are recoverable via the rebuild
    /// path (Slice 4) so failures here don't propagate.
    private func deleteFromDisk(id: String) {
        guard let fileStore else { return }
        do {
            _ = try fileStore.delete(id: id)
        } catch {
            Log.storage.error("NoteStore.deleteFromDisk failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
