import Foundation
import GRDB

/// Loads `MeetingBriefCandidate`s from the database: recent sessions (with
/// attendees, summary, open action items and People-index names) plus notes
/// whose text matches the event title (FTS). Read-only; safe off the main
/// actor.
struct MeetingBriefRepository: Sendable {

    let dbManager: DatabaseManager

    /// How far back to look for related meetings.
    static let lookback: TimeInterval = 180 * 24 * 60 * 60
    static let maxSessions = 400
    static let maxNotes = 20

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    /// Candidates for `event` (meetings before `now`, plus title-matching
    /// notes).
    func candidates(for event: CalendarEventInfo, now: Date) throws -> [MeetingBriefCandidate] {
        // People index: which normalised names appeared in which session.
        let people = (try? PeopleRepository(dbManager: dbManager).loadPeople()) ?? []
        var peopleBySession: [String: Set<String>] = [:]
        for person in people {
            let keys = Set(person.aliases + [person.id])
            for meeting in person.meetings {
                peopleBySession[meeting.sessionId, default: []].formUnion(keys)
            }
        }

        let peopleKeysBySession = peopleBySession
        let since = now.addingTimeInterval(-Self.lookback)
        let titleTerms = MeetingRetrieval.extractTerms(from: event.title)
            .filter { !MeetingBriefBuilder.titleStopWords.contains($0) }
        let ftsQuery = MeetingRetrieval.ftsOrQuery(terms: titleTerms)

        return try dbManager.database.read { db in
            var out: [MeetingBriefCandidate] = []

            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT s.id AS id, s.title AS title, s.createdAt AS createdAt,
                       s.calendarEventId AS calendarEventId, s.attendees AS attendees,
                       s.noteId AS noteId, n.title AS noteTitle
                FROM sessions s
                LEFT JOIN notes n ON n.id = s.noteId
                WHERE s.createdAt < ? AND s.createdAt >= ?
                ORDER BY s.createdAt DESC
                LIMIT ?
                """, arguments: [now, since, Self.maxSessions])

            var summaries: [String: (summary: String, questions: [String])] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT session_id, summary, follow_up_questions FROM meeting_summaries
                """) {
                let sessionId: String = row["session_id"]
                let questionsJSON: String? = row["follow_up_questions"]
                summaries[sessionId] = (
                    summary: (row["summary"] as String?) ?? "",
                    questions: Self.decodeStringArray(questionsJSON)
                )
            }

            var openItems: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT session_id, description, assignee FROM action_items
                WHERE is_completed = 0
                """) {
                let sessionId: String = row["session_id"]
                let description: String = (row["description"] as String?) ?? ""
                let assignee: String? = row["assignee"]
                let trimmedOwner = assignee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let line = trimmedOwner.isEmpty ? description : "\(description) — \(trimmedOwner)"
                openItems[sessionId, default: []].append(line)
            }

            var meetingNoteIds = Set<String>()
            for row in sessionRows {
                let id: String = row["id"]
                let attendeesJSON: String? = row["attendees"]
                let noteId: String? = row["noteId"]
                if let noteId { meetingNoteIds.insert(noteId) }
                let summary = summaries[id]
                out.append(MeetingBriefCandidate(
                    id: id,
                    kind: .meeting,
                    title: (row["title"] as String?) ?? "",
                    noteId: noteId,
                    noteTitle: row["noteTitle"],
                    date: (row["createdAt"] as Date?) ?? Date.distantPast,
                    calendarEventId: row["calendarEventId"],
                    attendees: CalendarAttendee.decodeList(fromJSON: attendeesJSON),
                    peopleKeys: peopleKeysBySession[id] ?? [],
                    summary: summary?.summary,
                    openActionItems: openItems[id] ?? [],
                    openQuestions: summary?.questions ?? []
                ))
            }

            // Notes that mention the title's words — scored on title
            // similarity by the builder. FTS failures (odd query) are ignored.
            if !ftsQuery.isEmpty {
                let noteRows = (try? Row.fetchAll(db, sql: """
                    SELECT n.id AS id, n.title AS title, n.updatedAt AS updatedAt
                    FROM notes_fts
                    JOIN notes n ON n.id = notes_fts.noteId
                    WHERE notes_fts MATCH ?
                    LIMIT ?
                    """, arguments: [ftsQuery, Self.maxNotes])) ?? []
                for row in noteRows {
                    let id: String = row["id"]
                    guard !meetingNoteIds.contains(id) else { continue }
                    let title: String = (row["title"] as String?) ?? ""
                    out.append(MeetingBriefCandidate(
                        id: id,
                        kind: .note,
                        title: title,
                        noteId: id,
                        noteTitle: title,
                        date: (row["updatedAt"] as Date?) ?? Date.distantPast
                    ))
                }
            }
            return out
        }
    }

    /// `["a","b"]` JSON text → array; anything else → [].
    static func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
