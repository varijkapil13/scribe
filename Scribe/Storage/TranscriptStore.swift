import Foundation
import GRDB
import Combine

/// High-level query interface for reading and writing transcription data.
// @unchecked Sendable is safe: DatabaseQueue is thread-safe and dbManager is
// immutable after init — no mutable state crosses actor boundaries.
final class TranscriptStore: @unchecked Sendable {

    // MARK: - Properties

    nonisolated(unsafe) static let shared = TranscriptStore()

    private let dbManager: DatabaseManager

    /// Convenience accessor for the underlying database queue.
    private var db: DatabaseQueue { dbManager.database }

    // MARK: - Initializer

    init(databaseManager: DatabaseManager = .shared) {
        self.dbManager = databaseManager
    }

    // MARK: - Session CRUD

    /// Creates a session attached to a Note. Every session must belong to a
    /// note — transcripts are part of notes, not standalone entities.
    @discardableResult
    func createSession(title: String, noteId: String) throws -> Session {
        var session = Session(title: title, noteId: noteId)
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

    // MARK: - Note binding

    /// Binds a session to a note (or detaches when passed `nil`).
    ///
    /// Production callers should pass `noteId` to `createSession` directly.
    /// This API remains for tests that exercise the bind/detach path and for
    /// the migration backfill (which operates in raw SQL anyway).
    func bindSession(_ sessionId: String, toNote noteId: String?) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE sessions SET noteId = ? WHERE id = ?",
                arguments: [noteId, sessionId]
            )
        }
    }

    /// Returns all sessions bound to a note, most recent first.
    func fetchSessions(forNoteId noteId: String) throws -> [Session] {
        try db.read { database in
            try Session
                .filter(Column("noteId") == noteId)
                .order(Column("createdAt").desc)
                .fetchAll(database)
        }
    }

    /// Observes the list of sessions bound to a note. Re-emits on bind/unbind.
    func observeSessions(forNoteId noteId: String) -> AnyPublisher<[Session], Error> {
        ValueObservation
            .tracking { database in
                try Session
                    .filter(Column("noteId") == noteId)
                    .order(Column("createdAt").desc)
                    .fetchAll(database)
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
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

    /// Moves segments to a different session, preserving wall-clock alignment.
    ///
    /// Each segment's wall-clock time (`source.createdAt + segment.startMs`) is
    /// re-expressed as an offset from the target session's `createdAt`. If any
    /// moved segment begins earlier than the target's `createdAt`, the target
    /// session's `createdAt` is shifted backward to accommodate it and the
    /// target's existing segments are bumped forward by the same amount so
    /// their wall-clock alignment is also preserved.
    ///
    /// Recomputes `endedAt` / `durationSeconds` for both the source and target
    /// sessions.
    ///
    /// - Parameters:
    ///   - ids: The auto-incremented segment row ids to move.
    ///   - toSessionId: Destination session id.
    func moveSegments(ids: [Int64], toSessionId: String) throws {
        guard !ids.isEmpty else { return }
        try db.write { database in
            let segments = try Segment
                .filter(ids.contains(Column("id")))
                .order(Column("startMs").asc)
                .fetchAll(database)
            guard !segments.isEmpty else { return }

            guard var target = try Session.fetchOne(database, key: toSessionId) else { return }

            let sourceIds = Set(segments.map { $0.sessionId })
            // Cache source createdAt values so we don't re-fetch per segment.
            var sourceCreatedAt: [String: Date] = [:]
            for sid in sourceIds {
                if let s = try Session.fetchOne(database, key: sid) {
                    sourceCreatedAt[sid] = s.createdAt
                }
            }

            // Compute each moved segment's absolute wall-clock start/end.
            struct MovedAbs { let id: Int64; let startAbs: Date; let endAbs: Date; let speaker: String; let text: String }
            var moved: [MovedAbs] = []
            moved.reserveCapacity(segments.count)
            for seg in segments {
                guard let segId = seg.id, let createdAt = sourceCreatedAt[seg.sessionId] else { continue }
                let startAbs = createdAt.addingTimeInterval(TimeInterval(seg.startMs) / 1000)
                let endAbs = createdAt.addingTimeInterval(TimeInterval(seg.endMs) / 1000)
                moved.append(MovedAbs(id: segId, startAbs: startAbs, endAbs: endAbs, speaker: seg.speaker, text: seg.text))
            }
            guard !moved.isEmpty else { return }

            let earliestAbs = moved.map { $0.startAbs }.min()!

            // If the moved selection starts before target.createdAt, slide the
            // target session's origin back so all timestamps stay non-negative
            // and the target's existing segments retain their wall-clock time.
            if earliestAbs < target.createdAt {
                let shiftMs = Int((target.createdAt.timeIntervalSince(earliestAbs) * 1000).rounded())
                if shiftMs > 0 {
                    try database.execute(
                        sql: "UPDATE segments SET startMs = startMs + ?, endMs = endMs + ? WHERE sessionId = ?",
                        arguments: [shiftMs, shiftMs, toSessionId]
                    )
                    target.createdAt = earliestAbs
                    try target.update(database)
                }
            }

            // Re-fetch in case createdAt changed.
            let targetCreatedAt = target.createdAt

            for m in moved {
                let newStart = Int((m.startAbs.timeIntervalSince(targetCreatedAt) * 1000).rounded())
                let newEnd = Int((m.endAbs.timeIntervalSince(targetCreatedAt) * 1000).rounded())
                try database.execute(
                    sql: "UPDATE segments SET sessionId = ?, startMs = ?, endMs = ? WHERE id = ?",
                    arguments: [toSessionId, newStart, newEnd, m.id]
                )
            }

            for sid in sourceIds.union([toSessionId]) {
                try Self.recomputeSessionDuration(database, sessionId: sid)
            }
        }
    }

    /// Recomputes a session's `endedAt` / `durationSeconds` from its current
    /// segments. Used after moves so both source and target reflect their new
    /// content lengths.
    private static func recomputeSessionDuration(_ database: Database, sessionId: String) throws {
        guard var session = try Session.fetchOne(database, key: sessionId) else { return }
        let lastEndMs = try Segment
            .filter(Column("sessionId") == sessionId)
            .order(Column("endMs").desc)
            .fetchOne(database)?
            .endMs

        if let lastEndMs {
            session.endedAt = session.createdAt.addingTimeInterval(TimeInterval(lastEndMs) / 1000)
            session.durationSeconds = lastEndMs / 1000
        } else {
            session.endedAt = session.createdAt
            session.durationSeconds = 0
        }
        try session.update(database)
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

    // MARK: - Crash Recovery

    /// Finalises any sessions left with `endedAt == nil` (a prior process
    /// crashed mid-recording). Sets `endedAt` to the latest segment's `endMs`
    /// (relative to `createdAt`) when segments exist, otherwise to `createdAt`
    /// — and recomputes `durationSeconds`.
    ///
    /// Returns the number of sessions that were recovered, so callers can log
    /// or surface the action.
    @discardableResult
    func recoverIncompleteSessions() throws -> Int {
        try db.write { database in
            let dangling = try Session
                .filter(Column("endedAt") == nil)
                .fetchAll(database)

            for var session in dangling {
                let lastEndMs = try Segment
                    .filter(Column("sessionId") == session.id)
                    .order(Column("endMs").desc)
                    .fetchOne(database)?
                    .endMs

                let endedAt: Date
                let duration: Int
                if let lastEndMs {
                    endedAt = session.createdAt.addingTimeInterval(TimeInterval(lastEndMs) / 1000)
                    duration = lastEndMs / 1000
                } else {
                    // No segments captured before the crash. Mark the session
                    // as zero-length and ended at its creation time so the UI
                    // still has a valid record to show.
                    endedAt = session.createdAt
                    duration = 0
                }

                session.endedAt = endedAt
                session.durationSeconds = duration
                try session.update(database)
            }

            return dangling.count
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

    // MARK: - Meeting Summaries

    /// Saves a meeting summary to the database.
    func saveSummary(_ summary: MeetingSummary) throws {
        try db.write { database in
            let iso8601 = ISO8601DateFormatter()
            let keyDecisionsJSON = try String(data: JSONEncoder().encode(summary.keyDecisions), encoding: .utf8) ?? "[]"
            let keyTopicsJSON = try String(data: JSONEncoder().encode(summary.keyTopics), encoding: .utf8) ?? "[]"
            let followUpJSON = try String(data: JSONEncoder().encode(summary.followUpQuestions), encoding: .utf8) ?? "[]"

            // INSERT OR REPLACE keys on `id` (the primary key), so calling
            // `saveSummary` twice with different summary ids would otherwise
            // leave duplicate rows for the same session. Clear any existing
            // summary for this session first so the API contract — one summary
            // per session — holds.
            try database.execute(
                sql: "DELETE FROM meeting_summaries WHERE session_id = ?",
                arguments: [summary.sessionId]
            )

            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO meeting_summaries
                        (id, session_id, summary, key_decisions, key_topics, follow_up_questions, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    summary.id.uuidString,
                    summary.sessionId,
                    summary.summary,
                    keyDecisionsJSON,
                    keyTopicsJSON,
                    followUpJSON,
                    iso8601.string(from: summary.createdAt)
                ]
            )

            // Persist associated action items into the action_items table.
            try saveActionItemsInTransaction(
                database,
                items: summary.actionItems,
                sessionId: summary.sessionId,
                summaryId: summary.id.uuidString
            )
        }
    }

    /// Fetches the summary for a session, if one exists.
    func fetchSummary(sessionId: String) throws -> MeetingSummary? {
        try db.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM meeting_summaries WHERE session_id = ?",
                arguments: [sessionId]
            ) else {
                return nil
            }

            let iso8601 = ISO8601DateFormatter()
            let decoder = JSONDecoder()

            let summaryId: String = row["id"]
            let summaryText: String = row["summary"]
            let keyDecisionsStr: String = row["key_decisions"]
            let keyTopicsStr: String = row["key_topics"]
            let followUpStr: String = row["follow_up_questions"]
            let createdAtStr: String = row["created_at"]

            let keyDecisions = (try? decoder.decode([String].self, from: Data(keyDecisionsStr.utf8))) ?? []
            let keyTopics = (try? decoder.decode([String].self, from: Data(keyTopicsStr.utf8))) ?? []
            let followUpQuestions = (try? decoder.decode([String].self, from: Data(followUpStr.utf8))) ?? []
            let createdAt = iso8601.date(from: createdAtStr) ?? Date()

            // Fetch associated action items.
            let actionItems = try fetchActionItemsFromDatabase(database, sessionId: sessionId)

            guard let uuid = UUID(uuidString: summaryId) else { return nil }

            return MeetingSummary(
                id: uuid,
                sessionId: sessionId,
                summary: summaryText,
                keyDecisions: keyDecisions,
                actionItems: actionItems,
                keyTopics: keyTopics,
                followUpQuestions: followUpQuestions,
                createdAt: createdAt
            )
        }
    }

    /// Deletes the summary for a session.
    func deleteSummary(sessionId: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM meeting_summaries WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
    }

    // MARK: - Action Items

    /// Saves action items for a session.
    func saveActionItems(_ items: [ActionItem], sessionId: String, summaryId: String?) throws {
        try db.write { database in
            try saveActionItemsInTransaction(database, items: items, sessionId: sessionId, summaryId: summaryId)
        }
    }

    /// Fetches all action items for a session.
    func fetchActionItems(sessionId: String) throws -> [ActionItem] {
        try db.read { database in
            try fetchActionItemsFromDatabase(database, sessionId: sessionId)
        }
    }

    /// Fetches all incomplete action items across all sessions.
    func fetchAllPendingActionItems() throws -> [(ActionItem, Session)] {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT a.*, s.id AS s_id, s.title AS s_title, s.createdAt AS s_createdAt,
                       s.endedAt AS s_endedAt, s.durationSeconds AS s_durationSeconds,
                       s.language AS s_language, s.tags AS s_tags
                FROM action_items a
                JOIN sessions s ON s.id = a.session_id
                WHERE a.is_completed = 0
                ORDER BY a.priority ASC
                """)

            return rows.compactMap { row -> (ActionItem, Session)? in
                guard let item = Self.actionItemFromRow(row),
                      let session = Self.sessionFromPrefixedRow(row) else {
                    return nil
                }
                return (item, session)
            }
        }
    }

    /// Toggles the completion state of an action item.
    func toggleActionItemCompletion(id: String) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE action_items SET is_completed = CASE WHEN is_completed = 0 THEN 1 ELSE 0 END WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Returns the identifiers of action items marked as completed for a session.
    ///
    /// The detail view uses this to hydrate its local completion-state set so
    /// checkmarks persist across reopens.
    func fetchCompletedActionItemIds(sessionId: String) throws -> Set<UUID> {
        try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT id FROM action_items WHERE session_id = ? AND is_completed = 1",
                arguments: [sessionId]
            )
            return Set(rows.compactMap { row -> UUID? in
                guard let idStr: String = row["id"] else { return nil }
                return UUID(uuidString: idStr)
            })
        }
    }

    // MARK: - Extracted Entities

    /// Saves extracted entities for a session (replaces existing).
    func saveEntities(_ entities: [ExtractedEntity], sessionId: String) throws {
        try db.write { database in
            // Remove existing entities for this session.
            try database.execute(
                sql: "DELETE FROM extracted_entities WHERE session_id = ?",
                arguments: [sessionId]
            )

            for entity in entities {
                try database.execute(
                    sql: """
                        INSERT INTO extracted_entities (id, session_id, text, entity_type, count)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        entity.id.uuidString,
                        sessionId,
                        entity.text,
                        entity.type.rawValue,
                        1
                    ]
                )
            }
        }
    }

    /// Fetches cached entities for a session.
    func fetchEntities(sessionId: String) throws -> [ExtractedEntity] {
        try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM extracted_entities WHERE session_id = ?",
                arguments: [sessionId]
            )

            return rows.compactMap { row -> ExtractedEntity? in
                guard let idStr: String = row["id"],
                      let uuid = UUID(uuidString: idStr),
                      let text: String = row["text"],
                      let typeStr: String = row["entity_type"],
                      let entityType = ExtractedEntity.EntityType(rawValue: typeStr) else {
                    return nil
                }
                return ExtractedEntity(
                    id: uuid,
                    text: text,
                    type: entityType,
                    range: nil,
                    segmentId: nil
                )
            }
        }
    }

    // MARK: - Private Helpers

    /// Inserts action items within an existing database write transaction.
    private func saveActionItemsInTransaction(
        _ database: Database,
        items: [ActionItem],
        sessionId: String,
        summaryId: String?
    ) throws {
        // Remove existing action items for this session + summary combination.
        if let summaryId = summaryId {
            try database.execute(
                sql: "DELETE FROM action_items WHERE session_id = ? AND summary_id = ?",
                arguments: [sessionId, summaryId]
            )
        } else {
            try database.execute(
                sql: "DELETE FROM action_items WHERE session_id = ? AND summary_id IS NULL",
                arguments: [sessionId]
            )
        }

        for item in items {
            try database.execute(
                sql: """
                    INSERT INTO action_items
                        (id, session_id, summary_id, description, assignee, deadline, priority, source_text, is_completed)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                    """,
                arguments: [
                    item.id.uuidString,
                    sessionId,
                    summaryId,
                    item.description,
                    item.assignee,
                    item.deadline,
                    item.priority?.rawValue,
                    item.sourceText
                ]
            )
        }
    }

    /// Fetches action items for a session within an existing database read context.
    private func fetchActionItemsFromDatabase(_ database: Database, sessionId: String) throws -> [ActionItem] {
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT * FROM action_items WHERE session_id = ? ORDER BY priority ASC",
            arguments: [sessionId]
        )
        return rows.compactMap { Self.actionItemFromRow($0) }
    }

    /// Converts a database row into an ActionItem.
    private static func actionItemFromRow(_ row: Row) -> ActionItem? {
        guard let idStr: String = row["id"],
              let uuid = UUID(uuidString: idStr),
              let description: String = row["description"] else {
            return nil
        }
        let assignee: String? = row["assignee"]
        let deadline: String? = row["deadline"]
        let priorityStr: String? = row["priority"]
        let priority = priorityStr.flatMap { ActionItem.Priority(rawValue: $0) }
        let sourceText: String = row["source_text"] ?? ""

        return ActionItem(
            id: uuid,
            description: description,
            assignee: assignee,
            deadline: deadline,
            priority: priority,
            sourceText: sourceText
        )
    }

    /// Builds a Session from a row with prefixed column names (s_id, s_title, etc.).
    private static func sessionFromPrefixedRow(_ row: Row) -> Session? {
        guard let id: String = row["s_id"],
              let title: String = row["s_title"],
              let createdAt: Date = row["s_createdAt"] else {
            return nil
        }
        let endedAt: Date? = row["s_endedAt"]
        let durationSeconds: Int? = row["s_durationSeconds"]
        let language: String? = row["s_language"]
        let tagsString: String = row["s_tags"] ?? "[]"
        let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsString.utf8))) ?? []

        return Session(
            id: id,
            title: title,
            createdAt: createdAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            language: language,
            tags: tags
        )
    }
}
