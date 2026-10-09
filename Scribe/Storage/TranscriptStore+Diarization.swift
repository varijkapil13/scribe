import Foundation
import GRDB

extension TranscriptStore {

    /// Remote segments of a session that the user hasn't reassigned by hand,
    /// in the shape `DiarizedSegmentRebuilder` works on.
    func fetchDiarizableSegments(sessionId: String) throws -> [DiarizedSegmentRebuilder.Stored] {
        try fetchSegments(sessionId: sessionId).compactMap { segment in
            guard let id = segment.id,
                  SpeakerNameResolver.canonicalKey(segment.speaker) == SpeakerNameResolver.remoteKey,
                  segment.speakerOverride == nil else { return nil }
            return DiarizedSegmentRebuilder.Stored(
                id: id, startMs: segment.startMs, endMs: segment.endMs, text: segment.text
            )
        }
    }

    /// Applies diarization changes in one transaction. Segments the user
    /// reassigned in the meantime are left alone; split segments keep their
    /// `remote` source with a per-part speaker override, so "reset speaker"
    /// still returns them to Remote.
    func applyDiarization(_ changes: [DiarizedSegmentRebuilder.Change], sessionId: String) throws {
        guard !changes.isEmpty else { return }
        try dbManager.database.write { database in
            for change in changes {
                switch change {
                case .relabel(let id, let key):
                    try database.execute(
                        sql: "UPDATE segments SET speakerOverride = ? WHERE id = ? AND speakerOverride IS NULL",
                        arguments: [key, id]
                    )
                case .split(let id, let parts):
                    guard let original = try Segment.fetchOne(database, key: id),
                          original.speakerOverride == nil else { continue }
                    _ = try Segment.deleteOne(database, key: id)
                    for part in parts {
                        let segment = Segment(
                            sessionId: sessionId,
                            startMs: part.startMs,
                            endMs: part.endMs,
                            speaker: original.speaker,
                            text: part.text,
                            speakerOverride: part.speakerKey
                        )
                        try segment.insert(database)
                    }
                }
            }
        }
    }
}
