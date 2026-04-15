import Foundation
import GRDB
import Combine

/// High-level query interface for reading and writing transcription data.
final class TranscriptStore {

    // MARK: - Properties

    private let dbManager: DatabaseManager

    /// Convenience accessor for the underlying database queue.
    private var db: DatabaseQueue { dbManager.database }

    // MARK: - Initializer

    init(databaseManager: DatabaseManager = .shared) {
        self.dbManager = databaseManager
    }

    // MARK: - Session CRUD

    /// Creates a new session with the given title and returns it.
    @discardableResult
    func createSession(title: String) throws -> Session {
        var session = Session(title: title)
        try db.write { database in
            try session.insert(database)
        }
        return session
    }

    /// Persists changes to an existing session.
    func updateSession(_ session: Session) throws {
        try db.write { database in
            try session.update(database)
        }
    }

    /// Marks a session as ended, setting `endedAt` to now and computing
    /// `durationSeconds` from the difference between `createdAt` and `endedAt`.
    func endSession(id: String) throws {
        try db.write { database in
            guard var session = try Session.fetchOne(database, key: id) else {
                return
            }
            let now = Date()
            session.endedAt = now
            session.durationSeconds = Int(now.timeIntervalSince(session.createdAt))
            try session.update(database)
        }
    }

    /// Deletes a session and all its segments (cascade).
    func deleteSession(id: String) throws {
        try db.write { database in
            _ = try Session.deleteOne(database, key: id)
        }
    }

    /// Returns all sessions ordered by creation date, most recent first.
    func fetchAllSessions() throws -> [Session] {
        try db.read { database in
            try Session.order(Column("createdAt").desc).fetchAll(database)
        }
    }

    /// Returns a single session by id, or nil if not found.
    func fetchSession(id: String) throws -> Session? {
        try db.read { database in
            try Session.fetchOne(database, key: id)
        }
    }

    // MARK: - Segment CRUD

    /// Adds a transcript segment and returns the inserted record (with its generated id).
    @discardableResult
    func addSegment(
        sessionId: String,
        startMs: Int,
        endMs: Int,
        speaker: String,
        text: String
    ) throws -> Segment {
        var segment = Segment(
            sessionId: sessionId,
            startMs: startMs,
            endMs: endMs,
            speaker: speaker,
            text: text
        )
        try db.write { database in
            try segment.insert(database)
        }
        return segment
    }

    /// Returns all segments for a session, ordered by start time.
    func fetchSegments(sessionId: String) throws -> [Segment] {
        try db.read { database in
            try Segment
                .filter(Column("sessionId") == sessionId)
                .order(Column("startMs").asc)
                .fetchAll(database)
        }
    }

    // MARK: - Full-Text Search

    /// Searches all transcripts using FTS5 and groups matching segments by session.
    ///
    /// Returns an array of `(Session, [Segment])` pairs, ordered by session creation date
    /// (most recent first). Only sessions that contain at least one matching segment are included.
    func searchTranscripts(query: String) throws -> [(Session, [Segment])] {
        try db.read { database in
            // Find matching segment row ids via FTS5.
            let matchingRows = try Row.fetchAll(database, sql: """
                SELECT rowid FROM segments_fts WHERE segments_fts MATCH ?
                """, arguments: [query])

            let rowIDs = matchingRows.map { $0[Column("rowid")] as Int64 }

            guard !rowIDs.isEmpty else { return [] }

            // Fetch the full Segment records for the matched row ids.
            let segments = try Segment
                .filter(rowIDs.contains(Column("id")))
                .order(Column("startMs").asc)
                .fetchAll(database)

            // Group segments by sessionId.
            let grouped = Dictionary(grouping: segments, by: { $0.sessionId })

            // Fetch the corresponding sessions and pair them up.
            var results: [(Session, [Segment])] = []
            for (sessionId, sessionSegments) in grouped {
                if let session = try Session.fetchOne(database, key: sessionId) {
                    results.append((session, sessionSegments))
                }
            }

            // Sort by session creation date, most recent first.
            results.sort { $0.0.createdAt > $1.0.createdAt }
            return results
        }
    }

    // MARK: - Bulk Operations

    /// Deletes all sessions and segments from the database.
    func deleteAllData() throws {
        try db.write { database in
            _ = try Segment.deleteAll(database)
            _ = try Session.deleteAll(database)
        }
    }

    // MARK: - Combine Observation

    /// Returns a Combine publisher that emits the current list of segments for a
    /// session whenever the underlying data changes.
    func observeSegments(sessionId: String) -> DatabasePublishers.Value<[Segment]> {
        let observation = ValueObservation.tracking { database in
            try Segment
                .filter(Column("sessionId") == sessionId)
                .order(Column("startMs").asc)
                .fetchAll(database)
        }
        return observation.publisher(in: db, scheduling: .immediate)
    }
}
