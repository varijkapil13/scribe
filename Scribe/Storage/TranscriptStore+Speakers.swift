import Foundation
import GRDB

/// Speaker naming persistence (migration `v18_speaker_names`).
///
/// - `session_speakers(sessionId, speakerKey, displayName)` renames a speaker
///   key for one session (`"remote"` → `"Priya"`).
/// - `segments.speakerOverride` reassigns individual segments to another
///   speaker key.
///
/// See `SpeakerNameResolver` for how keys turn into names.
extension TranscriptStore {

    /// Session-specific display names keyed by speaker key.
    func fetchSpeakerNames(sessionId: String) throws -> [String: String] {
        try dbManager.database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT speakerKey, displayName FROM session_speakers WHERE sessionId = ?",
                arguments: [sessionId]
            )
            var names: [String: String] = [:]
            for row in rows {
                let key: String = row["speakerKey"]
                let name: String = row["displayName"]
                names[key] = name
            }
            return names
        }
    }

    /// Sets (or, with an empty/whitespace name, clears) the display name for
    /// `speakerKey` in `sessionId`.
    func setSpeakerName(_ displayName: String, forKey speakerKey: String, sessionId: String) throws {
        let key = SpeakerNameResolver.canonicalKey(speakerKey)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try dbManager.database.write { database in
            if name.isEmpty {
                try database.execute(
                    sql: "DELETE FROM session_speakers WHERE sessionId = ? AND speakerKey = ?",
                    arguments: [sessionId, key]
                )
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO session_speakers (sessionId, speakerKey, displayName)
                        VALUES (?, ?, ?)
                        ON CONFLICT(sessionId, speakerKey) DO UPDATE SET displayName = excluded.displayName
                        """,
                    arguments: [sessionId, key, name]
                )
            }
        }
    }

    /// Reassigns segments to `speakerKey`. Pass `nil` to restore the original
    /// source attribution. Assigning a segment to its own source key clears
    /// the override rather than storing a redundant one.
    func setSpeakerOverride(_ speakerKey: String?, forSegmentIds ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let key = speakerKey.map(SpeakerNameResolver.canonicalKey)
        try dbManager.database.write { database in
            for id in ids {
                guard let segment = try Segment.fetchOne(database, key: id) else { continue }
                let stored: String?
                if let key, !key.isEmpty, key != SpeakerNameResolver.canonicalKey(segment.speaker) {
                    stored = key
                } else {
                    stored = nil
                }
                try database.execute(
                    sql: "UPDATE segments SET speakerOverride = ? WHERE id = ?",
                    arguments: [stored, id]
                )
            }
        }
    }

    /// A resolver for `sessionId` combining its stored names with the global
    /// "you" default. Falls back to defaults alone if the lookup fails.
    func speakerResolver(sessionId: String, defaults: UserDefaults = .standard) -> SpeakerNameResolver {
        let names = (try? fetchSpeakerNames(sessionId: sessionId)) ?? [:]
        return SpeakerNamePreferences.resolver(sessionNames: names, defaults: defaults)
    }

    /// Whether the session has any custom naming (names or reassignments).
    func hasCustomSpeakers(sessionId: String) throws -> Bool {
        try dbManager.database.read { database in
            let named = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM session_speakers WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
            if named > 0 { return true }
            let overridden = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM segments WHERE sessionId = ? AND speakerOverride IS NOT NULL",
                arguments: [sessionId]
            ) ?? 0
            return overridden > 0
        }
    }
}
