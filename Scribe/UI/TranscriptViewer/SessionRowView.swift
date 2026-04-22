import SwiftUI

/// Row view for displaying a session summary in the transcript list sidebar.
///
/// Layout: two-line card with the title on the first line and metadata
/// (relative date · duration) on the second, with tag chips wrapping below.
struct SessionRowView: View {

    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                .font(.system(.body, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(relativeDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let duration = session.durationSeconds, duration > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Label(formattedDuration(duration), systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                if let language = session.language?.uppercased(), !language.isEmpty, language != "AUTO" {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(language)
                        .font(.system(.caption2, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                }
            }

            if !session.tags.isEmpty {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(session.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    if session.tags.count > 3 {
                        Text("+\(session.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Helpers

    /// Formats as "Today · 2:30 PM", "Yesterday", or "Apr 12" depending on
    /// recency. Matches Notes / Mail / Things 3 conventions.
    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named

        let calendar = Calendar.current
        if calendar.isDateInToday(session.createdAt) {
            let time = session.createdAt.formatted(date: .omitted, time: .shortened)
            return "Today · \(time)"
        }
        if calendar.isDateInYesterday(session.createdAt) {
            let time = session.createdAt.formatted(date: .omitted, time: .shortened)
            return "Yesterday · \(time)"
        }
        // Last week → weekday name
        if let daysAgo = calendar.dateComponents([.day], from: session.createdAt, to: Date()).day,
           daysAgo < 7 {
            return session.createdAt.formatted(.dateTime.weekday(.wide))
        }
        // Same year → "Apr 12"
        if calendar.component(.year, from: session.createdAt) == calendar.component(.year, from: Date()) {
            return session.createdAt.formatted(.dateTime.month(.abbreviated).day())
        }
        // Older → "Apr 12, 2024"
        return session.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
