import Foundation

/// Pure formatting for bookmarked moments: timestamps, the transcript line a
/// bookmark points at, the "Highlights" markdown written into the meeting
/// note, the emphasis section added to summary prompts, and timeline marker
/// positions. No database or UI — fully unit-tested.
enum SessionBookmarkFormatter {

    /// Kind of the Scribe block (`NoteScribeBlocks`) holding a session's
    /// highlights inside its note.
    nonisolated static let noteBlockKind = "highlights"

    /// A bookmark looks back this far for the line it refers to: people
    /// usually hit the hotkey just *after* the moment that mattered.
    nonisolated static let lookbackMs = 30_000

    /// Longest transcript quote shown next to a highlight.
    nonisolated static let maxQuoteChars = 160

    // MARK: Timestamps

    /// "m:ss" under an hour, "h:mm:ss" from an hour (matches the player).
    nonisolated static func shortTimestamp(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "[hh:mm:ss]" — the same form `Segment.formattedTimestamp` uses in
    /// prompts, so the model can line bookmarks up with transcript lines.
    nonisolated static func promptTimestamp(ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "[%02d:%02d:%02d]", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: Context

    /// Index of the segment a bookmark at `offsetMs` refers to: the latest
    /// segment containing the offset, otherwise the latest one that started
    /// within `lookbackMs` before it. `segments` must be sorted by `startMs`.
    nonisolated static func contextIndex(offsetMs: Int, in segments: [Segment], lookbackMs: Int = SessionBookmarkFormatter.lookbackMs) -> Int? {
        var containing: Int?
        var lastStarted: Int?
        for (index, segment) in segments.enumerated() {
            guard segment.startMs <= offsetMs else { break }
            lastStarted = index
            if offsetMs <= max(segment.endMs, segment.startMs) {
                containing = index
            }
        }
        if let containing { return containing }
        guard let lastStarted else { return nil }
        let segment = segments[lastStarted]
        let end = max(segment.endMs, segment.startMs)
        return offsetMs - end <= lookbackMs ? lastStarted : nil
    }

    /// Whitespace-collapsed text, shortened with an ellipsis.
    nonisolated static func quote(_ text: String, maxChars: Int = SessionBookmarkFormatter.maxQuoteChars) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > maxChars, maxChars > 1 else { return collapsed }
        return String(collapsed.prefix(maxChars - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Highlights markdown

    /// One highlight line:
    /// `- **12:34** Pricing decision — Priya: “We ship on the 14th.”`
    nonisolated static func highlightLine(
        _ bookmark: SessionBookmark,
        segments: [Segment],
        speakerName: (Segment) -> String
    ) -> String {
        var line = "- **\(shortTimestamp(ms: bookmark.offsetMs))**"
        if let label = bookmark.trimmedLabel {
            line += " \(label)"
        }
        if let index = contextIndex(offsetMs: bookmark.offsetMs, in: segments) {
            let segment = segments[index]
            let text = quote(segment.text)
            if !text.isEmpty {
                let speaker = speakerName(segment).trimmingCharacters(in: .whitespaces)
                let who = speaker.isEmpty ? "" : "\(speaker): "
                line += (bookmark.trimmedLabel == nil ? " " : " — ") + "\(who)“\(text)”"
            }
        } else if bookmark.trimmedLabel == nil {
            line += " Marked moment"
        }
        return line
    }

    /// Bullet list of every bookmark, earliest first. Empty string when there
    /// are none.
    nonisolated static func highlightsMarkdown(
        bookmarks: [SessionBookmark],
        segments: [Segment],
        speakerName: (Segment) -> String
    ) -> String {
        let sortedSegments = segments.sorted { $0.startMs < $1.startMs }
        return sorted(bookmarks)
            .map { highlightLine($0, segments: sortedSegments, speakerName: speakerName) }
            .joined(separator: "\n")
    }

    /// Note block content: a heading plus the highlight list, or nil when
    /// there's nothing to write.
    nonisolated static func noteBlockContent(
        bookmarks: [SessionBookmark],
        segments: [Segment],
        speakerName: (Segment) -> String
    ) -> String? {
        let list = highlightsMarkdown(bookmarks: bookmarks, segments: segments, speakerName: speakerName)
        guard !list.isEmpty else { return nil }
        return "## Highlights\n\n" + list
    }

    // MARK: Prompt emphasis

    /// Section appended to summary prompts so bookmarked moments get extra
    /// weight, or nil without bookmarks. Capped at `limit` moments.
    nonisolated static func emphasisSection(bookmarks: [SessionBookmark], limit: Int = 12) -> String? {
        let ordered = sorted(bookmarks)
        guard !ordered.isEmpty else { return nil }
        let lines = ordered.prefix(max(1, limit)).map { bookmark -> String in
            let stamp = promptTimestamp(ms: bookmark.offsetMs)
            if let label = bookmark.trimmedLabel { return "- \(stamp) \(label)" }
            return "- \(stamp) (no label)"
        }
        return """
        HIGHLIGHTED MOMENTS:
        The user bookmarked these moments as important while the meeting was \
        happening. Give the discussion at and just before these timestamps \
        extra weight, and make sure the summary covers them.
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: Timeline markers

    /// Horizontal position (0…1) of a marker on a timeline `durationSeconds`
    /// long, or nil when the duration is unknown.
    nonisolated static func markerFraction(offsetMs: Int, durationSeconds: Double) -> Double? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let fraction = (Double(max(0, offsetMs)) / 1000) / durationSeconds
        return min(max(fraction, 0), 1)
    }

    /// Bookmarks ordered by offset, then id / creation.
    nonisolated static func sorted(_ bookmarks: [SessionBookmark]) -> [SessionBookmark] {
        bookmarks.sorted { lhs, rhs in
            if lhs.offsetMs != rhs.offsetMs { return lhs.offsetMs < rhs.offsetMs }
            return (lhs.id ?? Int64.max) < (rhs.id ?? Int64.max)
        }
    }
}
