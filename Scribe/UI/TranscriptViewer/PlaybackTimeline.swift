import Foundation

/// Pure helpers for session-audio playback: which segment is playing,
/// time formatting, seek clamping and the speed cycle. No AVFoundation, so
/// it's fully unit-testable.
enum PlaybackTimeline {

    /// Playback speeds offered by the player, in cycle order.
    static let rates: [Float] = [1.0, 1.5, 2.0]

    /// The speed after `rate` in ``rates`` (wrapping); unknown rates reset to 1×.
    static func nextRate(after rate: Float) -> Float {
        guard let index = rates.firstIndex(of: rate) else { return rates[0] }
        return rates[(index + 1) % rates.count]
    }

    /// Label for a speed: "1×", "1.5×", "2×".
    static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return String(format: "%.1f×", Double(rate))
    }

    /// The segment playing at `timeMs`, given segments sorted by `startMs`.
    ///
    /// Prefers the latest-starting segment whose `[startMs, endMs]` contains
    /// the time (mic and system segments can overlap); otherwise the latest
    /// segment that has already started, so the highlight stays on the last
    /// spoken line through a pause. Returns nil before the first segment.
    static func currentSegmentIndex(at timeMs: Int, in segments: [Segment]) -> Int? {
        var lastStarted: Int?
        var lastContaining: Int?
        for (index, segment) in segments.enumerated() {
            guard segment.startMs <= timeMs else { break }
            lastStarted = index
            if timeMs <= max(segment.endMs, segment.startMs) {
                lastContaining = index
            }
        }
        return lastContaining ?? lastStarted
    }

    /// Id of the segment playing at `timeMs` (see ``currentSegmentIndex(at:in:)``).
    static func currentSegmentId(at timeMs: Int, in segments: [Segment]) -> Int64? {
        guard let index = currentSegmentIndex(at: timeMs, in: segments) else { return nil }
        return segments[index].id
    }

    /// Clamps a seek target (seconds) into `0...duration`.
    static func clampedSeek(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), max(duration, 0))
    }

    /// Seconds for a segment start offset in milliseconds.
    static func seconds(fromMs ms: Int) -> TimeInterval {
        TimeInterval(max(ms, 0)) / 1000
    }

    /// "m:ss" under an hour, "h:mm:ss" from an hour. Negative / non-finite
    /// values read as 0:00.
    static func format(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
