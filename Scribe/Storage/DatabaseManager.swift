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
                t.primaryKey(["sourceNoteId", "targetNoteId", "anchorText"])
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

        try migrator.migrate(database)
    }
}
