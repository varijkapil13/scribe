import Foundation

/// Exports a transcript session as a Markdown document.
///
/// Consecutive segments from the same speaker are grouped under a single
/// speaker heading to improve readability.
struct MarkdownExporter {

    static func export(session: Session, segments: [Segment]) -> String {
        var lines: [String] = []

        // Header
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("**Date:** \(formatDate(session.createdAt))")
        lines.append("**Duration:** \(formatDuration(session.durationSeconds))")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Group consecutive segments by the same speaker.
        let groups = groupConsecutiveSegments(segments)

        for (index, group) in groups.enumerated() {
            guard let first = group.first else { continue }

            lines.append("**\(formatTimestamp(first.startMs)) \(first.speaker):**")

            let combinedText = group.map(\.text).joined(separator: " ")
            lines.append(combinedText)

            if index < groups.count - 1 {
                lines.append("")
            }
        }

        // Ensure trailing newline.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private Helpers

    /// Groups consecutive segments that share the same speaker label.
    private static func groupConsecutiveSegments(_ segments: [Segment]) -> [[Segment]] {
        guard !segments.isEmpty else { return [] }

        var groups: [[Segment]] = []
        var currentGroup: [Segment] = [segments[0]]

        for segment in segments.dropFirst() {
            if segment.speaker == currentGroup.last?.speaker {
                currentGroup.append(segment)
            } else {
                groups.append(currentGroup)
                currentGroup = [segment]
            }
        }
        groups.append(currentGroup)

        return groups
    }

    /// Formats a `Date` as a human-readable string (e.g. "Apr 15, 2026 at 2:30 PM").
    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Formats a duration in seconds as "Xh Ym Zs", omitting zero-valued leading
    /// components.
    private static func formatDuration(_ seconds: Int?) -> String {
        guard let seconds = seconds, seconds > 0 else { return "N/A" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }

    /// Formats a millisecond offset as `[HH:MM:SS]`.
    private static func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "[%02d:%02d:%02d]", hours, minutes, seconds)
    }
}
