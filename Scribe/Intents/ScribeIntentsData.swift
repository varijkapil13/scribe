import Foundation
import GRDB

/// Store access for the App Intents layer (entity queries + intents).
///
/// A thin facade over the existing GRDB stores so queries read exactly what
/// the app shows. Holds explicit store instances so tests can run it against
/// an in-memory `DatabaseManager`; production code uses `.live`.
struct ScribeIntentsData {

    let dbManager: DatabaseManager
    let noteStore: NoteStore
    let taskStore: TaskStore
    let transcriptStore: TranscriptStore

    /// How many items a suggestion / search list returns.
    static let listLimit = 25

    /// The app's shared stores.
    static var live: ScribeIntentsData {
        ScribeIntentsData(
            dbManager: .shared,
            noteStore: .shared,
            taskStore: .shared,
            transcriptStore: .shared
        )
    }

    // MARK: - Notes

    /// Notes for `ids`, in the order asked (missing ids skipped). Bodies are
    /// not loaded (list rows carry `bodyExcerpt`).
    func notes(ids: [String]) throws -> [Note] {
        guard !ids.isEmpty else { return [] }
        let rows = try dbManager.database.read { database in
            try Note.filter(keys: ids).fetchAll(database)
        }
        return ScribeIntentsText.ordered(rows, byIds: ids, id: \.id)
    }

    /// Most recently edited notes first.
    func recentNotes(limit: Int = ScribeIntentsData.listLimit) throws -> [Note] {
        try dbManager.database.read { database in
            try Note
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(database)
        }
    }

    /// Full-text search over note titles + bodies (best match first). A blank
    /// query returns the most recent notes.
    func searchNotes(_ query: String, limit: Int = ScribeIntentsData.listLimit) throws -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recentNotes(limit: limit) }
        return try Array(noteStore.searchNotes(query: trimmed).prefix(limit))
    }

    /// Creates a note. Wiki-links in the body are indexed the same way the
    /// editor's save does (`createNote` alone doesn't index them).
    func createNote(title: String, body: String) throws -> Note {
        let created = try noteStore.createNote(title: title, body: body)
        if body.contains("[[") {
            try noteStore.updateNote(created, tags: [])
            return try noteStore.fetchNote(id: created.id) ?? created
        }
        return created
    }

    // MARK: - Tasks

    /// Tasks for `ids`, in the order asked (missing ids skipped).
    func tasks(ids: [String]) throws -> [TodoTask] {
        guard !ids.isEmpty else { return [] }
        let rows = try dbManager.database.read { database in
            try TodoTask.filter(keys: ids).fetchAll(database)
        }
        return ScribeIntentsText.ordered(rows, byIds: ids, id: \.id)
    }

    /// Open tasks due today or overdue — the Today list.
    func todayTasks(now: Date = Date(), calendar: Calendar = .current) throws -> [TodoTask] {
        try taskStore.fetchTasks(filter: .today, calendar: calendar, now: now)
    }

    /// Today's tasks first, then the rest of the open tasks.
    func suggestedTasks(limit: Int = ScribeIntentsData.listLimit, now: Date = Date()) throws -> [TodoTask] {
        let today = try todayTasks(now: now)
        let todayIds = Set(today.map(\.id))
        let rest = try taskStore.fetchTasks(filter: .all, now: now).filter { !todayIds.contains($0.id) }
        return Array((today + rest).prefix(limit))
    }

    /// Full-text search over open tasks (best match first). A blank query
    /// returns the suggestions.
    func searchTasks(_ query: String, limit: Int = ScribeIntentsData.listLimit) throws -> [TodoTask] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try suggestedTasks(limit: limit) }
        return try taskStore.searchTasks(query: trimmed, includeCompleted: false, limit: limit)
    }

    // MARK: - Meetings (transcript sessions)

    /// Sessions for `ids`, in the order asked (missing ids skipped).
    func sessions(ids: [String]) throws -> [Session] {
        guard !ids.isEmpty else { return [] }
        let rows = try dbManager.database.read { database in
            try Session.filter(keys: ids).fetchAll(database)
        }
        return ScribeIntentsText.ordered(rows, byIds: ids, id: \.id)
    }

    /// Newest meetings first.
    func recentSessions(limit: Int = ScribeIntentsData.listLimit) throws -> [Session] {
        try Array(transcriptStore.fetchAllSessions().prefix(limit))
    }

    /// Meetings whose title, calendar event or attendees match `query`.
    func sessions(matching query: String, limit: Int = ScribeIntentsData.listLimit) throws -> [Session] {
        let all = try transcriptStore.fetchAllSessions()
        return Array(ScribeIntentsText.sessions(all, matching: query).prefix(limit))
    }

    /// The newest meeting that has finished recording.
    func latestFinishedSession() throws -> Session? {
        try transcriptStore.fetchAllSessions().first { $0.endedAt != nil }
    }

    /// The meeting's summary as plain text, or nil when it has none.
    func summaryText(sessionId: String) throws -> String? {
        guard let summary = try transcriptStore.fetchSummary(sessionId: sessionId) else { return nil }
        let title = try transcriptStore.fetchSession(id: sessionId)?.title
        let text = ScribeIntentsText.summaryText(summary, title: title)
        return text.isEmpty ? nil : text
    }

    /// The meeting's transcript as plain text (speaker names resolved), or
    /// nil when the session doesn't exist or has no transcribed speech.
    func transcriptText(sessionId: String) throws -> String? {
        guard let session = try transcriptStore.fetchSession(id: sessionId) else { return nil }
        let segments = try transcriptStore.fetchSegments(sessionId: sessionId)
        guard !segments.isEmpty else { return nil }
        return PlainTextExporter.export(
            session: session,
            segments: segments,
            speakerNames: transcriptStore.speakerResolver(sessionId: sessionId)
        )
    }
}
