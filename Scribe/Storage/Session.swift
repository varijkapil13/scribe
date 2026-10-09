import Foundation
import GRDB

/// Represents a transcription session.
struct Session: Codable, Identifiable, Equatable {

    /// Unique identifier (UUID string).
    var id: String
    /// User-facing title for the session.
    var title: String
    /// When the session was created.
    var createdAt: Date
    /// When the session was ended (nil while still recording).
    var endedAt: Date?
    /// Total recording duration in seconds, computed when the session ends.
    var durationSeconds: Int?
    /// Language code used for transcription (e.g. "en-US").
    var language: String?
    /// Free-form tags associated with the session, stored as a JSON array in the database.
    var tags: [String]
    /// ID of the Note this session is bound to, or nil if unattached.
    var noteId: String?
    /// EventKit identifier of the calendar event this recording belongs to
    /// (macOS calendar integration), or nil when none matched.
    var calendarEventId: String?
    /// Title of that calendar event at recording time.
    var calendarEventTitle: String?
    /// The event's attendees, stored as a JSON array of `{name, email}` in the
    /// nullable `attendees` column (NULL when empty).
    var attendees: [CalendarAttendee]
    /// Absolute path of the folder holding this session's retained audio
    /// (`mic.m4a` / `system.m4a`), or nil when audio wasn't retained or has
    /// been deleted by the retention policy.
    var audioDirectory: String?

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        language: String? = nil,
        tags: [String] = [],
        noteId: String? = nil,
        calendarEventId: String? = nil,
        calendarEventTitle: String? = nil,
        attendees: [CalendarAttendee] = [],
        audioDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.language = language
        self.tags = tags
        self.noteId = noteId
        self.calendarEventId = calendarEventId
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.audioDirectory = audioDirectory
    }

    // MARK: - Codable (custom because tags are stored as JSON text)

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, endedAt, durationSeconds, language, tags, noteId, audioDirectory
        case calendarEventId, calendarEventTitle, attendees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        language = try container.decodeIfPresent(String.self, forKey: .language)

        // tags column is stored as a JSON-encoded string in SQLite.
        let tagsString = try container.decodeIfPresent(String.self, forKey: .tags) ?? "[]"
        if let data = tagsString.data(using: .utf8) {
            tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            tags = []
        }

        noteId = try container.decodeIfPresent(String.self, forKey: .noteId)
        calendarEventId = try container.decodeIfPresent(String.self, forKey: .calendarEventId)
        calendarEventTitle = try container.decodeIfPresent(String.self, forKey: .calendarEventTitle)
        attendees = CalendarAttendee.decodeList(
            fromJSON: try container.decodeIfPresent(String.self, forKey: .attendees)
        )
        audioDirectory = try container.decodeIfPresent(String.self, forKey: .audioDirectory)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(language, forKey: .language)

        // Encode tags as a JSON string for SQLite storage.
        let tagsData = try JSONEncoder().encode(tags)
        let tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
        try container.encode(tagsString, forKey: .tags)

        try container.encodeIfPresent(noteId, forKey: .noteId)
        try container.encodeIfPresent(calendarEventId, forKey: .calendarEventId)
        try container.encodeIfPresent(calendarEventTitle, forKey: .calendarEventTitle)
        try container.encodeIfPresent(CalendarAttendee.encodeList(attendees), forKey: .attendees)
        try container.encodeIfPresent(audioDirectory, forKey: .audioDirectory)
    }
}

// MARK: - Attendees

/// A meeting participant copied from a calendar event. Plain value type so it
/// stays portable (this file is also compiled into the iOS target) — the
/// EventKit mapping lives in the macOS-only `Scribe/Calendar/`.
struct CalendarAttendee: Codable, Equatable, Hashable, Sendable {
    var name: String
    var email: String?

    init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }

    /// Display form: the name, falling back to the email address.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return email ?? ""
    }

    /// JSON text for the `sessions.attendees` column; nil (SQL NULL) when the
    /// list is empty.
    static func encodeList(_ attendees: [CalendarAttendee]) -> String? {
        guard !attendees.isEmpty,
              let data = try? JSONEncoder().encode(attendees) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parses the `sessions.attendees` column. NULL or malformed JSON yields
    /// an empty list rather than failing the whole row decode.
    static func decodeList(fromJSON json: String?) -> [CalendarAttendee] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CalendarAttendee].self, from: data)) ?? []
    }
}

// MARK: - GRDB Conformances

extension Session: FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
}
