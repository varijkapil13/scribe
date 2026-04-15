import Foundation
import GRDB

/// Manages the SQLite database used by Scribe, including setup and migrations.
final class DatabaseManager {

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

        try migrator.migrate(database)
    }
}
