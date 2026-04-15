import Foundation
import GRDB

/// Represents a single transcript segment within a session.
struct Segment: Codable, Identifiable, Equatable {

    /// Auto-incrementing primary key (nil until inserted).
    var id: Int64?
    /// The session this segment belongs to.
    var sessionId: String
    /// Start time offset in milliseconds from the beginning of the session.
    var startMs: Int
    /// End time offset in milliseconds from the beginning of the session.
    var endMs: Int
    /// Speaker label (e.g. "Speaker 1").
    var speaker: String
    /// The transcribed text for this segment.
    var text: String

    // MARK: - Initializer

    init(
        id: Int64? = nil,
        sessionId: String,
        startMs: Int,
        endMs: Int,
        speaker: String,
        text: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }

    // MARK: - Computed Properties

    /// Formatted timestamp derived from `startMs`, e.g. "[00:01:23]".
    var formattedTimestamp: String {
        let totalSeconds = startMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "[%02d:%02d:%02d]", hours, minutes, seconds)
    }
}

// MARK: - GRDB Conformances

extension Segment: FetchableRecord, PersistableRecord {
    static let databaseTableName = "segments"

    /// Let GRDB auto-generate the id on insert.
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
