// Scribe/People/PeopleRepository.swift
import Foundation
import GRDB

// MARK: - Mention sources

/// Something that can report which people appeared in which sessions.
///
/// The built-in sources read extracted PERSON entities, named speaker
/// labels, and action-item assignees. Other features can plug in more —
/// e.g. calendar attendees — by conforming a type and passing it to
/// `PeopleRepository(extraSources:)`, without touching the index itself.
protocol PeopleMentionSource: Sendable {
    func mentions(in db: Database) throws -> [PersonMention]
}

/// PERSON entities saved by `TranscriptStore.saveEntities` (NaturalLanguage
/// named-entity extraction).
struct EntityMentionSource: PeopleMentionSource {
    func mentions(in db: Database) throws -> [PersonMention] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT session_id, text FROM extracted_entities WHERE entity_type = ?
            """, arguments: [ExtractedEntity.EntityType.person.rawValue])
        return rows.compactMap { row -> PersonMention? in
            guard let sessionId: String = row["session_id"],
                  let text: String = row["text"] else { return nil }
            return PersonMention(name: text, sessionId: sessionId, source: .entity)
        }
    }
}

/// Distinct speaker labels per session. Placeholder labels ("you",
/// "remote", "Speaker 2") are dropped by `PeopleIndex.isPlausibleName`, so
/// only speakers the user has actually named become people.
struct SpeakerMentionSource: PeopleMentionSource {
    func mentions(in db: Database) throws -> [PersonMention] {
        let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT sessionId, speaker FROM segments")
        return rows.compactMap { row -> PersonMention? in
            guard let sessionId: String = row["sessionId"],
                  let speaker: String = row["speaker"] else { return nil }
            return PersonMention(name: speaker, sessionId: sessionId, source: .speaker)
        }
    }
}

/// Assignees of summary action items.
struct AssigneeMentionSource: PeopleMentionSource {
    func mentions(in db: Database) throws -> [PersonMention] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT session_id, assignee FROM action_items
            WHERE assignee IS NOT NULL AND assignee != ''
            """)
        return rows.compactMap { row -> PersonMention? in
            guard let sessionId: String = row["session_id"],
                  let assignee: String = row["assignee"] else { return nil }
            return PersonMention(name: assignee, sessionId: sessionId, source: .assignee)
        }
    }
}

// MARK: - Repository

/// Loads the inputs for `PeopleIndex` from the database and builds the
/// people list. Read-only.
struct PeopleRepository: Sendable {

    let dbManager: DatabaseManager
    let sources: [any PeopleMentionSource]

    static let defaultSources: [any PeopleMentionSource] = [
        EntityMentionSource(),
        SpeakerMentionSource(),
        AssigneeMentionSource()
    ]

    init(dbManager: DatabaseManager = .shared, extraSources: [any PeopleMentionSource] = []) {
        self.dbManager = dbManager
        self.sources = Self.defaultSources + extraSources
    }

    func loadPeople() throws -> [Person] {
        let sources = self.sources
        let inputs: (mentions: [PersonMention], meetings: [String: PersonMeeting], tasks: [PersonTaskRef]) =
            try dbManager.database.read { db in
                var mentions: [PersonMention] = []
                for source in sources {
                    mentions += try source.mentions(in: db)
                }
                let meetings = try Self.meetings(db)
                let tasks = try Self.openTasks(db)
                return (mentions: mentions, meetings: meetings, tasks: tasks)
            }
        return PeopleIndex.build(mentions: inputs.mentions, meetings: inputs.meetings, tasks: inputs.tasks)
    }

    /// Finds one person by key, alias or name.
    func person(named query: String) throws -> Person? {
        PeopleIndex.find(query, in: try loadPeople())
    }

    // MARK: Queries

    private static func meetings(_ db: Database) throws -> [String: PersonMeeting] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id AS id, s.title AS title, s.createdAt AS createdAt,
                   s.noteId AS noteId, n.title AS noteTitle
            FROM sessions s
            LEFT JOIN notes n ON n.id = s.noteId
            """)
        var out: [String: PersonMeeting] = [:]
        for row in rows {
            let id: String = row["id"]
            out[id] = PersonMeeting(
                sessionId: id,
                sessionTitle: (row["title"] as String?) ?? "",
                date: (row["createdAt"] as Date?) ?? Date.distantPast,
                noteId: row["noteId"],
                noteTitle: row["noteTitle"]
            )
        }
        return out
    }

    private static func openTasks(_ db: Database) throws -> [PersonTaskRef] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id AS id, t.title AS title, t.dueAt AS dueAt, ai.assignee AS assignee
            FROM tasks t
            LEFT JOIN action_items ai ON ai.id = t.sourceActionItemId
            WHERE t.completedAt IS NULL AND t.cancelledAt IS NULL
            """)
        let tagRows = try Row.fetchAll(db, sql: "SELECT taskId, tag FROM task_tags")
        var tagsByTask: [String: [String]] = [:]
        for row in tagRows {
            let taskId: String = row["taskId"]
            let tag: String = row["tag"]
            tagsByTask[taskId, default: []].append(tag)
        }
        return rows.map { row -> PersonTaskRef in
            let id: String = row["id"]
            return PersonTaskRef(
                id: id,
                title: (row["title"] as String?) ?? "",
                dueAt: row["dueAt"],
                tags: tagsByTask[id] ?? [],
                assignee: row["assignee"]
            )
        }
    }
}
