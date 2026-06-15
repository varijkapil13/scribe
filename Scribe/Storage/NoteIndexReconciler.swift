import Foundation
import GRDB

/// Reconciles the SQLite note index against the on-disk markdown vault.
///
/// Disk is the source of truth (Phase 5 goal). The reconciler:
/// 1. Upserts every file under the vault root into `notes`,
///    overwriting the body / metadata fields from the file's
///    frontmatter and content.
/// 2. Rebuilds `note_tags` and `note_links` from the file's
///    frontmatter + parsed `[[wiki-links]]`.
/// 3. Deletes DB rows for ids that no longer have a matching file —
///    the user (or another device) deleted that note outside Scribe.
///
/// Idempotent: running twice in a row produces the same DB state as
/// running once. Designed to be called both on app launch and on every
/// file-system event from `NoteVaultWatcher`.
struct NoteIndexReconciler {
    let fileStore: NoteFileStore
    let dbManager: DatabaseManager

    init(fileStore: NoteFileStore, dbManager: DatabaseManager) {
        self.fileStore = fileStore
        self.dbManager = dbManager
    }

    /// Runs one full pass. Returns `(upserted, removed)` for caller-side
    /// logging. The whole reconciliation happens in a single GRDB write
    /// transaction so partial states are never visible to readers.
    @discardableResult
    func reconcile() throws -> (upserted: Int, removed: Int) {
        let files = try fileStore.listAll()
        let onDiskIds = Set(files.map(\.id))

        return try dbManager.database.write { db in
            var upserted = 0
            for file in files {
                try upsert(file: file, into: db)
                upserted += 1
            }

            // Drop DB rows whose files were deleted outside Scribe. The
            // cascade in `deleteNote` (sessions → segments etc.) doesn't
            // apply here because we want to keep linked sessions even if
            // the note file vanishes — the session deletion is a UI-level
            // confirmation flow. Just remove the notes row; sessions get
            // their `noteId` invalidated downstream by Slice 4's UI work.
            let dbIds = try String.fetchAll(db, sql: "SELECT id FROM notes")
            var removed = 0
            for id in dbIds where !onDiskIds.contains(id) {
                _ = try Note.deleteOne(db, key: id)
                try db.execute(sql: "DELETE FROM notes_fts WHERE noteId = ?", arguments: [id])
                Log.storage.info("NoteIndexReconciler: removed DB row for absent file id=\(id, privacy: .public)")
                removed += 1
            }
            return (upserted, removed)
        }
    }

    // MARK: - Private

    private func upsert(file: NoteFile, into db: Database) throws {
        let note = Note(
            id: file.id,
            title: file.frontmatter.title,
            body: file.body,
            createdAt: file.frontmatter.createdAt,
            updatedAt: file.frontmatter.updatedAt,
            isDailyNote: file.frontmatter.isDailyNote,
            dailyDate: file.frontmatter.dailyDate.map(Self.dailyDateFormatter.string(from:)),
            notebookId: file.frontmatter.notebookId,
            bodyExcerpt: Note.makeExcerpt(from: file.body)
        )
        // upsert(): INSERT, or UPDATE on primary-key conflict. Does not
        // trigger the FK cascade that INSERT OR REPLACE would, so linked
        // sessions stay intact.
        try note.upsert(db)

        // Rebuild tag rows from frontmatter.
        try db.execute(sql: "DELETE FROM note_tags WHERE noteId = ?", arguments: [file.id])
        for tag in NoteStore.normalizeTags(file.frontmatter.tags) {
            try NoteTagRow(noteId: file.id, tag: tag).insert(db, onConflict: .ignore)
        }

        // Rebuild wiki-link edges from the parsed body.
        try db.execute(sql: "DELETE FROM note_links WHERE sourceNoteId = ?", arguments: [file.id])
        let anchors = NoteStore.parseWikiLinks(from: file.body)
        for anchor in anchors {
            if let target = try Note
                .filter(sql: "LOWER(title) = LOWER(?)", arguments: [anchor])
                .fetchOne(db) {
                let link = NoteLinkRow(
                    sourceNoteId: file.id,
                    targetNoteId: target.id,
                    anchorText: anchor
                )
                try link.insert(db, onConflict: .ignore)
            }
        }

        // Rewrite the FTS row so search matches the disk body. Reconciler
        // is the canonical FTS author after Slice 5 — the trigger
        // mechanism is gone.
        try NoteStore.upsertFTS(db, noteId: file.id, title: note.title, body: file.body)
    }

    nonisolated private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
