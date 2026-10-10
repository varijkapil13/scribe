// Scribe/MediaImport/ImportedTranscriptAssembly.swift
import Foundation

/// Pure helpers behind importing a recording: merging recognizer results
/// into stored segments and pacing how fast decoded audio is fed to the
/// recognizer.

// MARK: - Coalescing

/// Merges consecutive recognizer results into transcript segments, like the
/// live path does (`AppState.ingestTranscribedSegment`), but on the audio
/// clock instead of wall time — an import runs much faster than real time.
enum ImportedTranscriptCoalescer {

    struct Piece: Equatable, Sendable {
        var startMs: Int
        var endMs: Int
        var speaker: String
        var text: String
    }

    /// A merged segment never spans more than this.
    static let defaultMaxSpanMs = 60_000
    /// A pause longer than this starts a new segment.
    static let defaultMaxGapMs = 4_000

    /// Sorts by start time, drops empty text and merges neighbours from the
    /// same speaker separated by at most `maxGapMs`, as long as the merged
    /// segment spans at most `maxSpanMs`.
    nonisolated static func coalesce(_ pieces: [Piece],
                                     maxSpanMs: Int = defaultMaxSpanMs,
                                     maxGapMs: Int = defaultMaxGapMs) -> [Piece] {
        let sorted = pieces
            .map { piece -> Piece in
                var copy = piece
                copy.text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.endMs = max(piece.endMs, piece.startMs)
                return copy
            }
            .filter { !$0.text.isEmpty }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startMs != rhs.element.startMs { return lhs.element.startMs < rhs.element.startMs }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var out: [Piece] = []
        for piece in sorted {
            if var last = out.last,
               last.speaker == piece.speaker,
               piece.startMs - last.endMs <= maxGapMs,
               max(last.endMs, piece.endMs) - last.startMs <= maxSpanMs {
                last.text += " " + piece.text
                last.endMs = max(last.endMs, piece.endMs)
                out[out.count - 1] = last
            } else {
                out.append(piece)
            }
        }
        return out
    }
}

// MARK: - Pacing

/// Back-pressure for feeding decoded audio to the speech analyzer, whose
/// input queue is unbounded: hold off while the recognizer is clearly behind
/// (finalized text lags the audio fed by more than `maxLagMs`) *and* still
/// busy (it reported something within the last `quietThresholdMs`). A quiet
/// recognizer is either done or chewing through silence, so feeding goes on
/// and the import can never stall.
enum ImportPacing {

    static let defaultMaxLagMs = 90_000
    static let defaultQuietThresholdMs = 1_500
    /// Upper bound on one wait, whatever the recognizer does.
    static let maxWaitMs = 60_000

    nonisolated static func shouldWait(fedMs: Int,
                                       transcribedMs: Int,
                                       quietForMs: Int,
                                       maxLagMs: Int = defaultMaxLagMs,
                                       quietThresholdMs: Int = defaultQuietThresholdMs) -> Bool {
        fedMs - transcribedMs > maxLagMs && quietForMs < quietThresholdMs
    }

    /// Whether the recognizer has gone quiet long enough after the last
    /// audio to stop it (it has caught up), or the wait timed out.
    nonisolated static func isDrained(quietForMs: Int, waitedMs: Int,
                                      quietNeededMs: Int = 2_500, timeoutMs: Int = 120_000) -> Bool {
        quietForMs >= quietNeededMs || waitedMs >= timeoutMs
    }

    /// Progress of the transcription stage in 0…1.
    nonisolated static func fraction(fedFrames: Int, totalSeconds: Double, sampleRate: Double) -> Double {
        guard totalSeconds > 0, sampleRate > 0 else { return 0 }
        let fed = Double(fedFrames) / sampleRate
        return min(max(fed / totalSeconds, 0), 1)
    }
}
