import Foundation
import GRDB

/// A moment the user bookmarked during a recording ("Mark moment", ⌃⌥M).
///
/// `offsetMs` is on the same timeline as `Segment.startMs` (milliseconds into
/// the session, pauses excluded), so a bookmark lines up with the transcript
/// and with retained-audio playback. Stored in `session_bookmarks`
/// (migration `v22_session_bookmarks`).
struct SessionBookmark: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Auto-incremented row id (nil until inserted).
    var id: Int64?
    var sessionId: String
    /// Milliseconds into the session.
    var offsetMs: Int
    /// Optional short label ("Pricing decision"). nil = unlabeled.
    var label: String?
    var createdAt: Date

    init(id: Int64? = nil, sessionId: String, offsetMs: Int, label: String? = nil, createdAt: Date) {
        self.id = id
        self.sessionId = sessionId
        self.offsetMs = offsetMs
        self.label = label
        self.createdAt = createdAt
    }

    /// The label trimmed, or nil when empty.
    var trimmedLabel: String? {
        SessionBookmarkStore.normalizedLabel(label)
    }
}

extension SessionBookmark: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "session_bookmarks"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// CRUD for `session_bookmarks`. Same threading model as `TranscriptStore`:
/// the GRDB queue serializes access, so the store is safe to share.
final class SessionBookmarkStore: @unchecked Sendable {

    nonisolated static let shared = SessionBookmarkStore(databaseManager: .shared)

    let dbManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.dbManager = databaseManager
    }

    /// Trimmed label, nil when empty / whitespace-only. Labels are capped so a
    /// pasted paragraph doesn't end up in every prompt.
    nonisolated static func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLabelLength))
    }

    nonisolated static let maxLabelLength = 120

    /// Adds a bookmark and returns it (with its row id).
    @discardableResult
    func add(sessionId: String, offsetMs: Int, label: String?, createdAt: Date) throws -> SessionBookmark {
        var bookmark = SessionBookmark(
            sessionId: sessionId,
            offsetMs: max(0, offsetMs),
            label: Self.normalizedLabel(label),
            createdAt: createdAt
        )
        try dbManager.database.write { db in
            try bookmark.insert(db)
        }
        return bookmark
    }

    /// Bookmarks of a session, earliest moment first.
    func fetch(sessionId: String) throws -> [SessionBookmark] {
        try dbManager.database.read { db in
            try SessionBookmark
                .filter(Column("sessionId") == sessionId)
                .order(Column("offsetMs"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Renames (or clears, with nil / empty) a bookmark's label.
    func updateLabel(id: Int64, label: String?) throws {
        let normalized = Self.normalizedLabel(label)
        try dbManager.database.write { db in
            try db.execute(
                sql: "UPDATE session_bookmarks SET label = ? WHERE id = ?",
                arguments: [normalized, id]
            )
        }
    }

    func delete(id: Int64) throws {
        try dbManager.database.write { db in
            try db.execute(sql: "DELETE FROM session_bookmarks WHERE id = ?", arguments: [id])
        }
    }
}
