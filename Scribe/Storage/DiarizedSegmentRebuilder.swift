import Foundation

/// Pure mapping from a diarization result onto stored transcript segments.
///
/// Scribe stores *coalesced* segments: consecutive recognizer results from
/// the same source are merged for up to a minute (see
/// `AppState.ingestTranscribedSegment`). One stored "remote" segment can
/// therefore contain several remote participants. To split it, the
/// recording keeps the raw recognizer results (`Piece`s) for the remote
/// stream; each piece is attributed to the diarized speaker it overlaps most,
/// and a stored segment whose pieces belong to different speakers is split
/// into one segment per consecutive run.
///
/// Foundation only (shared with the iOS target) and covered by tests.
enum DiarizedSegmentRebuilder {

    /// One diarized speaker turn, in seconds from the start of the system
    /// audio (which is the same timeline as segment `startMs`/`endMs`).
    struct Turn: Equatable, Sendable {
        let speakerId: String
        let start: Double
        let end: Double
    }

    /// One raw recognizer result from the remote stream.
    struct Piece: Equatable, Sendable {
        let startMs: Int
        let endMs: Int
        let text: String
    }

    /// A stored remote segment.
    struct Stored: Equatable, Sendable {
        let id: Int64
        let startMs: Int
        let endMs: Int
        let text: String
    }

    /// A replacement segment produced by a split.
    struct Part: Equatable, Sendable {
        let speakerKey: String
        let startMs: Int
        let endMs: Int
        let text: String
    }

    enum Change: Equatable, Sendable {
        /// Attribute the whole segment to `speakerKey`.
        case relabel(id: Int64, speakerKey: String)
        /// Replace the segment with `parts` (in time order).
        case split(id: Int64, parts: [Part])
    }

    /// Display key for the n-th distinct speaker (1-based).
    static func speakerKey(_ index: Int) -> String { "Speaker \(index)" }

    /// A piece/turn gap up to this many ms still counts as "nearest turn"
    /// when a piece overlaps no turn at all (diarization trims silences).
    static let nearestTurnToleranceMs = 1_000

    /// Computes the changes, or `[]` when diarization found fewer than two
    /// remote speakers (nothing to tell apart — keep plain "Remote").
    static func changes(stored: [Stored], pieces: [Piece], turns: [Turn]) -> [Change] {
        guard !turns.isEmpty, !stored.isEmpty else { return [] }

        let sortedPieces = pieces.sorted { $0.startMs < $1.startMs }
        let pieceSpeakers = sortedPieces.map { speaker(forStartMs: $0.startMs, endMs: $0.endMs, turns: turns) }

        // Name speakers by first appearance in the transcript.
        var labels: [String: String] = [:]
        func label(_ raw: String) -> String {
            if let existing = labels[raw] { return existing }
            let key = speakerKey(labels.count + 1)
            labels[raw] = key
            return key
        }

        // Pieces carry the finest timing; fall back to whole stored segments
        // when the recording has none (e.g. older sessions).
        var changes: [Change] = []
        let sortedStored = stored.sorted { $0.startMs < $1.startMs }
        for segment in sortedStored {
            let inside = zip(sortedPieces, pieceSpeakers).filter { piece, _ in
                let mid = (piece.startMs + piece.endMs) / 2
                return mid >= segment.startMs - 50 && mid <= segment.endMs + 50
            }
            let joined = inside.map { $0.0.text }.joined(separator: " ")
            let textMatches = !inside.isEmpty && normalized(joined) == normalized(segment.text)

            if textMatches {
                let runs = Self.runs(inside.map { ($0.0, $0.1) })
                if runs.count > 1 {
                    changes.append(.split(id: segment.id, parts: runs.map { run in
                        Part(
                            speakerKey: run.speaker.map(label) ?? speakerKey(1),
                            startMs: run.startMs,
                            endMs: run.endMs,
                            text: run.text
                        )
                    }))
                    continue
                }
                if let raw = runs.first?.speaker {
                    changes.append(.relabel(id: segment.id, speakerKey: label(raw)))
                    continue
                }
            }
            // Text was edited/moved, or no pieces: label by dominant overlap.
            if let raw = speaker(forStartMs: segment.startMs, endMs: segment.endMs, turns: turns) {
                changes.append(.relabel(id: segment.id, speakerKey: label(raw)))
            }
        }

        // One speaker only: leave the transcript as plain "Remote".
        return labels.count >= 2 ? changes : []
    }

    /// The turn speaker with the most overlap with `[startMs, endMs]`, or the
    /// nearest turn within tolerance when nothing overlaps.
    static func speaker(forStartMs startMs: Int, endMs: Int, turns: [Turn]) -> String? {
        let start = Double(startMs) / 1000, end = Double(max(endMs, startMs)) / 1000
        var overlap: [String: Double] = [:]
        for turn in turns {
            let amount = min(end, turn.end) - max(start, turn.start)
            if amount > 0 { overlap[turn.speakerId, default: 0] += amount }
        }
        if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return best.key
        }
        let tolerance = Double(nearestTurnToleranceMs) / 1000
        let nearest = turns.min { gap($0, start, end) < gap($1, start, end) }
        guard let nearest, gap(nearest, start, end) <= tolerance else { return nil }
        return nearest.speakerId
    }

    // MARK: - Private

    private struct Run {
        var speaker: String?
        var startMs: Int
        var endMs: Int
        var text: String
    }

    /// Groups consecutive pieces by speaker. A piece with no speaker joins the
    /// run before it (or the next one, at the start).
    private static func runs(_ items: [(Piece, String?)]) -> [Run] {
        var runs: [Run] = []
        for (piece, speaker) in items {
            if var last = runs.last, speaker == nil || speaker == last.speaker || last.speaker == nil {
                if last.speaker == nil { last.speaker = speaker }
                last.endMs = max(last.endMs, piece.endMs)
                last.text += " " + piece.text
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(speaker: speaker, startMs: piece.startMs, endMs: piece.endMs, text: piece.text))
            }
        }
        return runs
    }

    private static func gap(_ turn: Turn, _ start: Double, _ end: Double) -> Double {
        if end < turn.start { return turn.start - end }
        if start > turn.end { return start - turn.end }
        return 0
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
