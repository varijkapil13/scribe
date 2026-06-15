import Foundation
import GRDB

/// Manages the SQLite database used by Scribe, including setup and migrations.
///
/// Conforms to `@unchecked Sendable` because its only mutable state is the
/// GRDB `DatabaseQueue`, which serializes access internally.
final class DatabaseManager: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance using the default on-disk database path.
    static let shared: DatabaseManager = {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scribeDirectory = appSupportURL.appendingPathComponent("Scribe", isDirectory: true)

        // Create the directory if it doesn't already exist.
        try? fileManager.createDirectory(at: scribeDirectory, withIntermediateDirectories: true)

        let databaseURL = scribeDirectory.appendingPathComponent("scribe.db")
        // swiftlint:disable:next force_try
        return try! DatabaseManager(path: databaseURL.path)
    }()

    // MARK: - Properties

    /// The underlying GRDB database queue.
    let database: DatabaseQueue

    // MARK: - Initializer

    /// Creates a `DatabaseManager` backed by the database at the given file path.
    /// Pass `":memory:"` for an in-memory database (useful for tests).
    init(path: String) throws {
        database = try DatabaseQueue(path: path)
        try runMigrations()
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = Self.makeMigrator()
        try migrator.migrate(database)
    }

    /// Builds the project's full migrator (registers v1…vN in order).
    ///
    /// Exposed `internal` so tests can run migrations up to a specific step
    /// (e.g. `migrator.migrate(queue, upTo: "v10_session_noteId")`), insert
    /// fixture rows that simulate a legacy database state, then drive the
    /// next migration to verify its real SQL — instead of mirroring the
    /// migration body inline in a test, which can drift from production.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Always re-run migrations in development builds so schema changes
        // are picked up without bumping version numbers.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // -- sessions --
            try db.create(table: "sessions") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("durationSeconds", .integer)
                t.column("language", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")
            }

            // -- segments --
            try db.create(table: "segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
            }

            // -- FTS5 virtual table for full-text search on segment text --
            try db.execute(sql: """
                CREATE VIRTUAL TABLE segments_fts USING fts5(
                    text,
                    content='segments',
                    content_rowid='id'
                )
                """)

            // -- Triggers to keep FTS index in sync --

            try db.execute(sql: """
                CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                    INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
                    INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
                END
                """)
        }

        migrator.registerMigration("v2") { db in
            // -- meeting_summaries --
            try db.create(table: "meeting_summaries") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("summary", .text).notNull()
                t.column("key_decisions", .text).notNull().defaults(to: "[]")
                t.column("key_topics", .text).notNull().defaults(to: "[]")
                t.column("follow_up_questions", .text).notNull().defaults(to: "[]")
                t.column("created_at", .text).notNull()
            }

            // -- action_items --
            try db.create(table: "action_items") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("summary_id", .text)
                    .references("meeting_summaries", onDelete: .cascade)
                t.column("description", .text).notNull()
                t.column("assignee", .text)
                t.column("deadline", .text)
                t.column("priority", .text)
                t.column("source_text", .text).notNull().defaults(to: "")
                t.column("is_completed", .integer).notNull().defaults(to: 0)
            }

            // -- extracted_entities --
            try db.create(table: "extracted_entities") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("entity_type", .text).notNull()
                t.column("count", .integer).notNull().defaults(to: 1)
            }
        }

        migrator.registerMigration("v3") { db in
            // -- projects --
            try db.create(table: "projects") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("icon", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // -- tasks --
            //
            // `id` is a UUID string for stable cross-device references
            // (matches `sessions` / `action_items`). Sqlite still maintains an
            // implicit `rowid`, which we'll use later for FTS5 wiring.
            try db.create(table: "tasks") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("projectId", .text)
                    .references("projects", onDelete: .setNull)
                t.column("priority", .text)
                t.column("dueAt", .datetime)
                t.column("remindAt", .datetime)
                t.column("recurrenceRule", .text)
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("sourceSessionId", .text)
                    .references("sessions", onDelete: .setNull)
                t.column("sourceActionItemId", .text)
                    .references("action_items", onDelete: .setNull)
            }
            try db.create(index: "tasks_dueAt_idx", on: "tasks", columns: ["dueAt"])
            try db.create(index: "tasks_projectId_idx", on: "tasks", columns: ["projectId"])
            try db.create(index: "tasks_completedAt_idx", on: "tasks", columns: ["completedAt"])

            // -- task_tags (many-to-many) --
            try db.create(table: "task_tags") { t in
                t.column("taskId", .text).notNull()
                    .references("tasks", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["taskId", "tag"])
            }
            try db.create(index: "task_tags_tag_idx", on: "task_tags", columns: ["tag"])

            // -- task_completions (history for recurring tasks) --
            try db.create(table: "task_completions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskId", .text).notNull()
                    .references("tasks", onDelete: .cascade)
                t.column("completedAt", .datetime).notNull()
            }
            try db.create(index: "task_completions_taskId_idx",
                          on: "task_completions",
                          columns: ["taskId"])
        }

        migrator.registerMigration("v4") { db in
            // Indexes for the source-link FKs. Without them, deleting a
            // session or action item triggers a full scan over `tasks` to
            // satisfy ON DELETE SET NULL.
            try db.create(index: "tasks_sourceSessionId_idx",
                          on: "tasks",
                          columns: ["sourceSessionId"])
            try db.create(index: "tasks_sourceActionItemId_idx",
                          on: "tasks",
                          columns: ["sourceActionItemId"])
        }

        migrator.registerMigration("v5") { db in
            // -- FTS5 virtual table over tasks.title + notes --
            //
            // External-content table backed by `tasks`; uses the rowid join
            // pattern so FTS5 only stores the index. Triggers below keep the
            // index in sync with INSERT / UPDATE / DELETE on the parent.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE tasks_fts USING fts5(
                    title,
                    notes,
                    content='tasks',
                    content_rowid='rowid'
                )
                """)

            // Backfill FTS index from any rows already present.
            try db.execute(sql: """
                INSERT INTO tasks_fts(rowid, title, notes)
                SELECT rowid, title, notes FROM tasks
                """)

            try db.execute(sql: """
                CREATE TRIGGER tasks_fts_ai AFTER INSERT ON tasks BEGIN
                    INSERT INTO tasks_fts(rowid, title, notes)
                    VALUES (new.rowid, new.title, new.notes);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER tasks_fts_ad AFTER DELETE ON tasks BEGIN
                    INSERT INTO tasks_fts(tasks_fts, rowid, title, notes)
                    VALUES('delete', old.rowid, old.title, old.notes);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER tasks_fts_au AFTER UPDATE ON tasks BEGIN
                    INSERT INTO tasks_fts(tasks_fts, rowid, title, notes)
                    VALUES('delete', old.rowid, old.title, old.notes);
                    INSERT INTO tasks_fts(rowid, title, notes)
                    VALUES (new.rowid, new.title, new.notes);
                END
                """)
        }

        migrator.registerMigration("v6") { db in
            // -- notes --
            try db.create(table: "notes") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("body", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDailyNote", .boolean).notNull().defaults(to: false)
                t.column("dailyDate", .text)
            }
            try db.create(index: "notes_dailyDate_idx", on: "notes", columns: ["dailyDate"])
            try db.create(index: "notes_updatedAt_idx", on: "notes", columns: ["updatedAt"])

            // -- note_tags --
            try db.create(table: "note_tags") { t in
                t.column("noteId", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["noteId", "tag"])
            }
            try db.create(index: "note_tags_tag_idx", on: "note_tags", columns: ["tag"])

            // -- note_links --
            try db.create(table: "note_links") { t in
                t.column("sourceNoteId", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("targetNoteId", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("anchorText", .text).notNull()
                t.primaryKey(["sourceNoteId", "targetNoteId"])
            }
            try db.create(index: "note_links_targetNoteId_idx",
                          on: "note_links", columns: ["targetNoteId"])

            // -- notes_fts --
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    title,
                    body,
                    content='notes',
                    content_rowid='rowid'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
                    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
                    INSERT INTO notes_fts(notes_fts, rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
                    INSERT INTO notes_fts(notes_fts, rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END
                """)
        }

        migrator.registerMigration("v7") { db in
            // Add unique constraint on notes.dailyDate so concurrent
            // dailyNote(for:) calls cannot create duplicate daily notes.
            // SQLite doesn't support ADD CONSTRAINT, so a partial unique index
            // gives equivalent enforcement.
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS notes_dailyDate_unique_idx
                ON notes (dailyDate)
                WHERE isDailyNote = 1
                """)
        }

        migrator.registerMigration("v5_fix_note_links_pk") { db in
            try db.execute(sql: """
                CREATE TABLE note_links_new (
                    sourceNoteId TEXT NOT NULL,
                    targetNoteId TEXT NOT NULL,
                    anchorText   TEXT NOT NULL,
                    PRIMARY KEY (sourceNoteId, targetNoteId)
                )
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO note_links_new
                SELECT sourceNoteId, targetNoteId, anchorText FROM note_links
                """)
            try db.execute(sql: "DROP TABLE note_links")
            try db.execute(sql: "ALTER TABLE note_links_new RENAME TO note_links")
        }

        migrator.registerMigration("v8") { db in
            // -- notebooks --
            try db.create(table: "notebooks") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "notebooks_sortOrder_idx", on: "notebooks", columns: ["sortOrder"])

            // -- notes.notebookId (nil = Inbox / uncategorized) --
            try db.alter(table: "notes") { t in
                t.add(column: "notebookId", .text)
            }
            try db.create(index: "notes_notebookId_idx", on: "notes", columns: ["notebookId"])
        }

        // v5_fix_note_links_pk dropped FK constraints; restore them so cascade delete works.
        migrator.registerMigration("v9_restore_note_links_fk") { db in
            try db.execute(sql: """
                CREATE TABLE note_links_fk (
                    sourceNoteId TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    targetNoteId TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    anchorText   TEXT NOT NULL,
                    PRIMARY KEY (sourceNoteId, targetNoteId)
                )
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO note_links_fk
                SELECT sourceNoteId, targetNoteId, anchorText FROM note_links
                """)
            try db.execute(sql: "DROP TABLE note_links")
            try db.execute(sql: "ALTER TABLE note_links_fk RENAME TO note_links")
        }

        migrator.registerMigration("v10_session_noteId") { db in
            // sessions.noteId — links a recording session to a Note.
            // Column is nullable for backwards compatibility with v1–v9 rows;
            // v11 backfills every NULL with an auto-created "Meeting on …"
            // note so production never observes a NULL. FK is not enforced
            // via ALTER TABLE in this codebase (matches notes.notebookId
            // pattern); `NoteStore.deleteNote` cascades into `sessions`
            // explicitly, so deleting a note also removes its recordings.
            try db.alter(table: "sessions") { t in
                t.add(column: "noteId", .text)
            }
            try db.create(index: "sessions_noteId_idx",
                          on: "sessions",
                          columns: ["noteId"])
        }

        migrator.registerMigration("v11_session_noteId_backfill") { db in
            // Every existing session without a noteId gets an auto-created Note so
            // sessions can no longer exist outside a note. Idempotent: re-runs on a
            // migrated DB find no orphans and do nothing.
            let orphans = try Row.fetchAll(db, sql: """
                SELECT id, title, createdAt FROM sessions WHERE noteId IS NULL
                """)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for row in orphans {
                let sessionId: String = row["id"]
                let sessionTitle: String = row["title"]
                let createdAt: Date = row["createdAt"]
                let noteTitle = sessionTitle.isEmpty
                    ? "Meeting on \(formatter.string(from: createdAt))"
                    : sessionTitle
                let noteId = UUID().uuidString
                try db.execute(sql: """
                    INSERT INTO notes (id, title, body, createdAt, updatedAt, isDailyNote, dailyDate, notebookId)
                    VALUES (?, ?, '', ?, ?, 0, NULL, NULL)
                    """, arguments: [noteId, noteTitle, createdAt, Date()])
                try db.execute(sql: "UPDATE sessions SET noteId = ? WHERE id = ?",
                               arguments: [noteId, sessionId])
            }
        }

        migrator.registerMigration("v12_notebook_parentId") { db in
            try db.alter(table: "notebooks") { t in
                t.add(column: "parentId", .text).references("notebooks", onDelete: .setNull)
            }
        }

        // Phase 5 / Slice 5 — disk is the source of truth for note bodies.
        // SQLite keeps only metadata, derived indexes, and a short
        // `bodyExcerpt` for list-view previews. The notes_fts virtual
        // table is rebuilt as contentless so we can populate it from
        // disk content via the reconciler without trigger-driven
        // coupling to a now-dropped `notes.body` column.
        //
        // Migration order matters: we must flush every legacy
        // `notes.body` value to its `.md` file BEFORE dropping the
        // column, otherwise the disk-side store loses the only copy
        // of bodies that were never opened in-app between the Slice 3
        // migration and this one.
        migrator.registerMigration("v13_drop_notes_body") { db in
            // 1. Add the new `bodyExcerpt` column and backfill from body.
            try db.execute(sql: "ALTER TABLE notes ADD COLUMN bodyExcerpt TEXT")
            try db.execute(sql: "UPDATE notes SET bodyExcerpt = SUBSTR(body, 1, 200) WHERE body IS NOT NULL AND body != ''")

            // 2. Flush bodies to disk if not already there. Per-id
            //    existence-gated — running this migration multiple times
            //    (which shouldn't happen, but) is a no-op for already-
            //    flushed rows.
            if let dir = try? NotesDirectory.defaultLocation() {
                let store = NoteFileStore(directory: dir)
                let onDiskIds = Set(((try? store.listAll()) ?? []).map(\.id))
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, title, body, createdAt, updatedAt, isDailyNote, dailyDate, notebookId
                    FROM notes
                    """)
                for row in rows {
                    let id: String = row["id"]
                    if onDiskIds.contains(id) { continue }
                    let body: String = (row["body"] as String?) ?? ""
                    let createdAt: Date = row["createdAt"]
                    let updatedAt: Date = row["updatedAt"]
                    let title: String = (row["title"] as String?) ?? ""
                    let isDailyRaw: Int = (row["isDailyNote"] as Int?) ?? 0
                    let dailyDateStr: String? = row["dailyDate"]
                    let notebookId: String? = row["notebookId"]
                    let dailyDate = dailyDateStr.flatMap { Self.v13DailyFormatter.date(from: $0) }

                    let tagRows = try String.fetchAll(
                        db,
                        sql: "SELECT tag FROM note_tags WHERE noteId = ? ORDER BY tag",
                        arguments: [id]
                    )

                    let file = NoteFile(
                        id: id,
                        frontmatter: NoteFrontmatter(
                            title: title,
                            createdAt: createdAt,
                            updatedAt: updatedAt,
                            notebookId: notebookId,
                            tags: tagRows,
                            isDailyNote: isDailyRaw != 0,
                            dailyDate: dailyDate
                        ),
                        body: body
                    )
                    do {
                        try store.write(file)
                    } catch {
                        // Per-file failure shouldn't abort the migration —
                        // log and keep going. The body still lives in
                        // bodyExcerpt (truncated) and the file can be
                        // recovered from a backup if needed.
                        Log.storage.error("v13: failed to flush note \(id, privacy: .public) to disk: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            // 3. Replace trigger-driven notes_fts with a contentless one.
            try db.execute(sql: "DROP TRIGGER IF EXISTS notes_fts_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS notes_fts_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS notes_fts_au")
            try db.execute(sql: "DROP TABLE IF EXISTS notes_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    noteId UNINDEXED,
                    title,
                    body
                )
                """)
            // Repopulate FTS from notes + the about-to-drop body column.
            try db.execute(sql: """
                INSERT INTO notes_fts(noteId, title, body)
                SELECT id, title, COALESCE(body, '') FROM notes
                """)

            // 4. Drop the body column. SQLite ≥3.35 supports DROP COLUMN
            //    natively; macOS 14+ ships well above that floor.
            try db.execute(sql: "ALTER TABLE notes DROP COLUMN body")
        }

        // Tasks parity (TickTick): per-task checklist / subtasks. Additive — a
        // brand-new table + index; never touches the existing `tasks` table.
        migrator.registerMigration("v14_task_subtasks") { db in
            try db.create(table: "task_subtasks") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("taskId", .text).notNull()
                    .references("tasks", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "task_subtasks_taskId_idx",
                          on: "task_subtasks",
                          columns: ["taskId"])
        }

        // Tasks parity (TickTick): non-destructive "Won't do" / cancelled state
        // + a pin-to-top flag. Additive ALTERs; existing rows get NULL
        // cancelledAt (= active) and isPinned = 0.
        migrator.registerMigration("v15_task_cancelled_pinned") { db in
            try db.alter(table: "tasks") { t in
                t.add(column: "cancelledAt", .datetime)
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "tasks_cancelledAt_idx",
                          on: "tasks",
                          columns: ["cancelledAt"])
        }

        // Tombstones for deleted tasks so CloudKit sync can propagate deletes
        // (a deleted row is otherwise indistinguishable from "never existed").
        migrator.registerMigration("v16_task_tombstones") { db in
            try db.create(table: "task_tombstones") { t in
                t.column("id", .text).primaryKey()
                t.column("deletedAt", .datetime).notNull()
            }
        }

        return migrator
    }

    /// Date formatter used inside v13's body-flush step. POSIX local-time
    /// to match `NoteStore.dailyDateFormatter` and `NoteFileStore`.
    nonisolated(unsafe) private static let v13DailyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
