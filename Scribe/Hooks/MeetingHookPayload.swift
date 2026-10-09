import Foundation

/// The JSON document a post-meeting hook receives on stdin.
///
/// The key set is a public contract for user scripts: every key is always
/// present (absent values are `null`, empty lists are `[]`), keys are
/// snake_case and output is key-sorted. Bump `schema_version` on any
/// breaking change.
///
/// ```json
/// {
///   "action_items": [{"assignee": "Priya", "completed": false, "deadline": null,
///                     "description": "Send deck", "priority": "High"}],
///   "duration_seconds": 1830,
///   "ended_at": "2026-10-09T15:30:30Z",
///   "event": "meeting.ended",
///   "language": "en-US",
///   "note_id": "…", "note_path": "/…/Weekly sync.md", "note_title": "Weekly sync",
///   "schema_version": 1,
///   "segments": [{"end_ms": 4200, "speaker": "Priya", "speaker_key": "remote",
///                 "start_ms": 0, "text": "Morning!"}],
///   "session_id": "…",
///   "speakers": ["Priya", "Varij"],
///   "started_at": "2026-10-09T15:00:00Z",
///   "summary": {"follow_up_questions": [], "key_decisions": [], "key_topics": [],
///               "text": "…"},
///   "tags": [],
///   "title": "Weekly sync",
///   "transcript_markdown": "# Weekly sync\n…"
/// }
/// ```
struct MeetingHookPayload: Codable, Equatable {

    static let currentSchemaVersion = 1
    static let endedEvent = "meeting.ended"

    struct SegmentPayload: Codable, Equatable {
        let startMs: Int
        let endMs: Int
        /// Display name ("Priya", the user's name, …).
        let speaker: String
        /// Underlying key ("you", "remote", or a custom speaker).
        let speakerKey: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
            case speaker
            case speakerKey = "speaker_key"
            case text
        }
    }

    struct SummaryPayload: Codable, Equatable {
        let text: String
        let keyDecisions: [String]
        let keyTopics: [String]
        let followUpQuestions: [String]

        enum CodingKeys: String, CodingKey {
            case text
            case keyDecisions = "key_decisions"
            case keyTopics = "key_topics"
            case followUpQuestions = "follow_up_questions"
        }
    }

    struct ActionItemPayload: Codable, Equatable {
        let description: String
        let assignee: String?
        let deadline: String?
        let priority: String?
        let completed: Bool

        enum CodingKeys: String, CodingKey {
            case description, assignee, deadline, priority, completed
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(description, forKey: .description)
            try c.encode(assignee, forKey: .assignee)
            try c.encode(deadline, forKey: .deadline)
            try c.encode(priority, forKey: .priority)
            try c.encode(completed, forKey: .completed)
        }
    }

    let schemaVersion: Int
    let event: String
    let sessionId: String
    let title: String
    let noteId: String?
    let noteTitle: String?
    let notePath: String?
    /// ISO 8601 (UTC).
    let startedAt: String
    let endedAt: String?
    let durationSeconds: Int?
    let language: String?
    let tags: [String]
    /// Distinct speaker display names in order of first appearance.
    let speakers: [String]
    let segments: [SegmentPayload]
    let summary: SummaryPayload?
    let actionItems: [ActionItemPayload]
    let transcriptMarkdown: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case sessionId = "session_id"
        case title
        case noteId = "note_id"
        case noteTitle = "note_title"
        case notePath = "note_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case language
        case tags
        case speakers
        case segments
        case summary
        case actionItems = "action_items"
        case transcriptMarkdown = "transcript_markdown"
    }

    /// Always writes every key (optionals as `null`) so scripts can rely on
    /// a fixed shape.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(event, forKey: .event)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(title, forKey: .title)
        try c.encode(noteId, forKey: .noteId)
        try c.encode(noteTitle, forKey: .noteTitle)
        try c.encode(notePath, forKey: .notePath)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(language, forKey: .language)
        try c.encode(tags, forKey: .tags)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(segments, forKey: .segments)
        try c.encode(summary, forKey: .summary)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(transcriptMarkdown, forKey: .transcriptMarkdown)
    }

    // MARK: - Building

    /// Assembles the payload from stored meeting data. Pure: all lookups
    /// happen in the caller.
    static func make(
        session: Session,
        segments: [Segment],
        speakerNames: SpeakerNameResolver,
        noteTitle: String? = nil,
        notePath: String? = nil,
        summary: MeetingSummary? = nil,
        completedActionItemIds: Set<UUID> = []
    ) -> MeetingHookPayload {
        let segmentPayloads = segments.map { segment in
            SegmentPayload(
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: speakerNames.displayName(for: segment),
                speakerKey: SpeakerNameResolver.effectiveKey(for: segment),
                text: segment.text
            )
        }
        var speakers: [String] = []
        for payload in segmentPayloads where !speakers.contains(payload.speaker) {
            speakers.append(payload.speaker)
        }

        let summaryPayload = summary.map {
            SummaryPayload(
                text: $0.summary,
                keyDecisions: $0.keyDecisions,
                keyTopics: $0.keyTopics,
                followUpQuestions: $0.followUpQuestions
            )
        }
        let actionItems = (summary?.actionItems ?? []).map {
            ActionItemPayload(
                description: $0.description,
                assignee: $0.assignee,
                deadline: $0.deadline,
                priority: $0.priority?.rawValue,
                completed: completedActionItemIds.contains($0.id)
            )
        }

        return MeetingHookPayload(
            schemaVersion: currentSchemaVersion,
            event: endedEvent,
            sessionId: session.id,
            title: session.title,
            noteId: session.noteId,
            noteTitle: noteTitle,
            notePath: notePath,
            startedAt: iso8601(session.createdAt),
            endedAt: session.endedAt.map(iso8601),
            durationSeconds: session.durationSeconds,
            language: session.language,
            tags: session.tags,
            speakers: speakers,
            segments: segmentPayloads,
            summary: summaryPayload,
            actionItems: actionItems,
            transcriptMarkdown: MarkdownExporter.export(
                session: session,
                segments: segments,
                speakerNames: speakerNames
            )
        )
    }

    /// Compact, key-sorted UTF-8 JSON.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
