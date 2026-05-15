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

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        language: String? = nil,
        tags: [String] = [],
        noteId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.language = language
        self.tags = tags
        self.noteId = noteId
    }

    // MARK: - Codable (custom because tags are stored as JSON text)

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, endedAt, durationSeconds, language, tags, noteId
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
    }
}

// MARK: - GRDB Conformances

extension Session: FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
}
