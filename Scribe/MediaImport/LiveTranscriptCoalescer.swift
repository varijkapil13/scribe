import Foundation

/// Incremental version of ``ImportedTranscriptCoalescer`` for a live
/// recording: finalized recognizer results arrive one at a time and are
/// merged into the pending paragraph while they come from the same speaker,
/// follow it within `maxGapMs` (on the audio clock) and keep it under
/// `maxSpanMs`. Whatever no longer fits closes the paragraph, which the caller
/// persists as a segment right away — so a crash loses at most the paragraph
/// still being spoken.
///
/// Used by the iPhone / iPad recorder. The Mac's live path coalesces on wall
/// time inside `AppState` and is unchanged.
struct LiveTranscriptCoalescer: Equatable, Sendable {

    typealias Piece = ImportedTranscriptCoalescer.Piece

    let maxSpanMs: Int
    let maxGapMs: Int

    /// The paragraph still being spoken (shown live, not yet persisted).
    private(set) var pending: Piece?

    init(maxSpanMs: Int, maxGapMs: Int) {
        self.maxSpanMs = max(0, maxSpanMs)
        self.maxGapMs = max(0, maxGapMs)
    }

    /// Adds one finalized result. Returns the paragraph it closed, if any,
    /// for the caller to persist.
    mutating func ingest(_ piece: Piece) -> Piece? {
        var incoming = piece
        incoming.text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        incoming.endMs = max(piece.endMs, piece.startMs)
        guard !incoming.text.isEmpty else { return nil }

        guard var current = pending else {
            pending = incoming
            return nil
        }
        if current.speaker == incoming.speaker,
           incoming.startMs - current.endMs <= maxGapMs,
           max(current.endMs, incoming.endMs) - current.startMs <= maxSpanMs {
            current.text += " " + incoming.text
            current.endMs = max(current.endMs, incoming.endMs)
            pending = current
            return nil
        }
        pending = incoming
        return current
    }

    /// Closes the pending paragraph once the audio clock has moved more than
    /// `maxGapMs` past its end (the speaker stopped), so it is persisted even
    /// when no further speech arrives.
    mutating func closeIfIdle(audioClockMs: Int) -> Piece? {
        guard let current = pending, audioClockMs - current.endMs > maxGapMs else { return nil }
        pending = nil
        return current
    }

    /// Closes and returns the pending paragraph (end of the recording).
    mutating func flush() -> Piece? {
        let current = pending
        pending = nil
        return current
    }
}
