import Foundation

extension TranscriptStore {

    /// Segments of a session recorded under one of `speakerKeys` (e.g. the
    /// iPhone's "In person") that the user hasn't reassigned by hand, in the
    /// shape `DiarizedSegmentRebuilder` works on. The Mac's
    /// ``fetchDiarizableSegments(sessionId:)`` is this for `"remote"`.
    ///
    /// `applyDiarization(_:sessionId:)` works unchanged on the result: split
    /// parts keep the original source key with a per-part speaker override.
    func fetchDiarizableSegments(
        sessionId: String,
        speakerKeys: Set<String>
    ) throws -> [DiarizedSegmentRebuilder.Stored] {
        let keys = Set(speakerKeys.map(SpeakerNameResolver.canonicalKey))
        return try fetchSegments(sessionId: sessionId).compactMap { segment in
            guard let id = segment.id,
                  keys.contains(SpeakerNameResolver.canonicalKey(segment.speaker)),
                  segment.speakerOverride == nil else { return nil }
            return DiarizedSegmentRebuilder.Stored(
                id: id, startMs: segment.startMs, endMs: segment.endMs, text: segment.text
            )
        }
    }

    /// Speaker keys to show as chips for a session, in first-appearance
    /// order (effective keys, so diarized "Speaker 1…N" replace the source).
    func speakerKeysInOrder(sessionId: String) throws -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in try fetchSegments(sessionId: sessionId) {
            let key = SpeakerNameResolver.effectiveKey(for: segment)
            if !key.isEmpty, seen.insert(key).inserted { ordered.append(key) }
        }
        return ordered
    }
}
