import Foundation
import GRDB

/// Outcome of one reconcile pass.
struct NoteReconcileResult: Equatable, Sendable {
    var upserted: Int
    var removed: Int
    /// Files that had no `id:` and got their path-derived id pinned.
    var pinned: Int
    /// Ids whose file content changed since the previous pass (or since
    /// Scribe's own last write). Every id on a store's first pass.
    var changedNoteIds: Set<String>
}

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
/// 4. Pins the path-derived id into files that have no `id:` yet, so
///    their id never changes again.
///
/// The directory listing is taken *inside* the DB write transaction, and
/// `NoteStore` mirrors its file writes inside its own write transactions,
/// so a pass can never see "row written, file not yet" (and delete the
/// row) or "file removed, row not yet" (and resurrect it).
///
/// Idempotent: running twice in a row produces the same DB state as
/// running once. Designed to be called both on app launch and on every
/// file-system event from `NoteVaultWatcher` (serialised by
/// `NoteReconcileScheduler`).
struct NoteIndexReconciler: Sendable {
    let fileStore: NoteFileStore
    let dbManager: DatabaseManager

    init(fileStore: NoteFileStore, dbManager: DatabaseManager) {
        self.fileStore = fileStore
        self.dbManager = dbManager
    }

    /// Runs one full pass. Returns `(upserted, removed)` for caller-side
    /// logging. See `reconcileDetailed()`.
    @discardableResult
    func reconcile() throws -> (upserted: Int, removed: Int) {
        let result = try reconcileDetailed()
        return (result.upserted, result.removed)
    }

    /// Runs one full pass in a single GRDB write transaction so partial
    /// states are never visible to readers.
    func reconcileDetailed() throws -> NoteReconcileResult {
        // Parse changed files *before* taking the write lock: the listing
        // inside the transaction then re-reads nothing that is unchanged
        // since (one stat per file), so the database — which the main
        // thread also reads — is held only briefly. The authoritative
        // listing is still the one inside the transaction.
        // It leaves the id → path map alone: only a listing taken inside a
        // transaction is consistent with NoteStore's in-transaction writes.
        let warmChanged = (try? fileStore.listEntries(rebuildingIndex: false).changedIds) ?? []
        var result = try reconcileInTransaction()
        result.changedNoteIds.formUnion(warmChanged)
        return result
    }

    private func reconcileInTransaction() throws -> NoteReconcileResult {
        try dbManager.database.write { db in
            let listing = try fileStore.listEntries()
            var entries = Self.preferredEntries(listing.entries)

            var pinned = 0
            for i in entries.indices where !entries[i].hasExplicitId {
                let entry = entries[i]
                do {
                    entries[i] = try fileStore.pinStableId(for: entry)
                    pinned += 1
                } catch {
                    // Read-only file, evicted iCloud item, concurrent edit:
                    // the derived id is deterministic, so indexing under it
                    // is still stable. Try again next pass.
                    let path = entry.relativePath
                    let reason = error.localizedDescription
                    Log.storage.info("NoteIndexReconciler: couldn't pin id for \(path, privacy: .public): \(reason, privacy: .public)")
                }
            }

            let onDiskIds = Set(entries.map(\.file.id))

            // Drop DB rows whose files were deleted outside Scribe — before
            // the upserts, so a vanished note can't keep holding a daily
            // date that a file on disk now claims. The cascade in
            // `deleteNote` (sessions → segments etc.) doesn't
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

            // `notes.dailyDate` is UNIQUE. Two files can claim the same day
            // (a daily note created in-app before an iCloud-synced one was
            // indexed, a duplicated file, a keep-both conflict copy); one
            // failing upsert would abort every future pass. Give each day
            // to exactly one note and release it from every other row
            // before upserting, so the upserts can't collide in any order.
            let currentOwners = try Row.fetchAll(
                db,
                sql: "SELECT id, dailyDate FROM notes WHERE dailyDate IS NOT NULL"
            )
            var ownerByKey: [String: String] = [:]
            for row in currentOwners {
                let id: String = row["id"]
                let key: String = row["dailyDate"]
                ownerByKey[key] = id
            }
            let dailyKeys = Self.dailyKeyAssignments(entries, currentOwners: ownerByKey)
            for (key, id) in ownerByKey where dailyKeys[id] != key {
                try db.execute(sql: "UPDATE notes SET dailyDate = NULL WHERE id = ?", arguments: [id])
            }

            var upserted = 0
            for entry in entries {
                try upsert(file: entry.file, dailyKey: dailyKeys[entry.file.id], into: db)
                upserted += 1
            }
            // Links resolve against titles, so rebuild them only once every
            // row is in — otherwise a link to a note listed later is lost.
            for entry in entries {
                try rebuildLinks(for: entry.file, in: db)
            }
            return NoteReconcileResult(
                upserted: upserted,
                removed: removed,
                pinned: pinned,
                changedNoteIds: listing.changedIds
            )
        }
    }

    /// One entry per note id. When several files carry the same id (an
    /// iCloud `(conflicted copy)` duplicates the bytes, id included; a
    /// Finder duplicate does too), the regular file wins over a conflict
    /// copy, then the lexicographically first path — so the DB row is
    /// deterministic instead of "whichever file was listed last".
    nonisolated static func preferredEntries(_ entries: [NoteFileEntry]) -> [NoteFileEntry] {
        var chosen: [String: NoteFileEntry] = [:]
        var order: [String] = []
        for entry in entries {
            let id = entry.file.id
            guard let current = chosen[id] else {
                chosen[id] = entry
                order.append(id)
                continue
            }
            if NoteVaultIndex.isPreferred(entry.relativePath, over: current.relativePath) {
                chosen[id] = entry
            }
        }
        return order.compactMap { chosen[$0] }
    }

    /// Note id → the `dailyDate` key its row may hold. Each key goes to one
    /// note: the row that already holds it if that note still claims it
    /// (so an open daily note isn't swapped out from under the user),
    /// otherwise the preferred file path. Losing notes are indexed as
    /// ordinary notes; their files are left untouched.
    nonisolated static func dailyKeyAssignments(
        _ entries: [NoteFileEntry],
        currentOwners: [String: String]
    ) -> [String: String] {
        var claimants: [String: [NoteFileEntry]] = [:]
        for entry in entries {
            guard let key = dailyKey(for: entry.file) else { continue }
            claimants[key, default: []].append(entry)
        }
        var out: [String: String] = [:]
        for (key, group) in claimants {
            let winner: NoteFileEntry
            if let owner = currentOwners[key], let held = group.first(where: { $0.file.id == owner }) {
                winner = held
            } else {
                winner = group.dropFirst().reduce(group[0]) { best, next in
                    NoteVaultIndex.isPreferred(next.relativePath, over: best.relativePath) ? next : best
                }
            }
            out[winner.file.id] = key
        }
        return out
    }

    private static func dailyKey(for file: NoteFile) -> String? {
        file.frontmatter.dailyDate.map(dailyDateFormatter.string(from:))
    }

    // MARK: - Private

    private func upsert(file: NoteFile, dailyKey: String?, into db: Database) throws {
        let note = Note(
            id: file.id,
            title: file.frontmatter.title,
            body: file.body,
            createdAt: file.frontmatter.createdAt,
            updatedAt: file.frontmatter.updatedAt,
            // A note that lost its day to another file is indexed as an
            // ordinary note (see `dailyKeyAssignments`).
            isDailyNote: file.frontmatter.isDailyNote && (dailyKey != nil || file.frontmatter.dailyDate == nil),
            dailyDate: dailyKey,
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

        // Rewrite the FTS row so search matches the disk body. Reconciler
        // is the canonical FTS author after Slice 5 — the trigger
        // mechanism is gone.
        try NoteStore.upsertFTS(db, noteId: file.id, title: note.title, body: file.body)
    }

    private func rebuildLinks(for file: NoteFile, in db: Database) throws {
        // Rebuild wiki-link edges from the parsed body.
        try db.execute(sql: "DELETE FROM note_links WHERE sourceNoteId = ?", arguments: [file.id])
        let anchors = NoteStore.parseWikiLinks(from: file.body)
        for anchor in anchors {
            if let target = try NoteStore.resolveLinkTarget(db, anchor: anchor) {
                let link = NoteLinkRow(
                    sourceNoteId: file.id,
                    targetNoteId: target.id,
                    anchorText: anchor
                )
                try link.insert(db, onConflict: .ignore)
            }
        }
    }

    nonisolated private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
