import SwiftUI

/// Row view for displaying a session summary in the transcript list sidebar.
///
/// Layout: title on the first line, grey metadata (date, duration, tags) on the second.
struct SessionRowView: View {

    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                .font(DesignTokens.QuietList.rowTitleFont.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(relativeDate)

                if let duration = session.durationSeconds, duration > 0 {
                    Text(formattedDuration(duration))
                }

                if let language = session.language?.uppercased(), !language.isEmpty, language != "AUTO" {
                    Text(language)
                }

                if !session.tags.isEmpty {
                    Text(session.tags.prefix(3).map { "#\($0)" }.joined(separator: " ")
                         + (session.tags.count > 3 ? " +\(session.tags.count - 3)" : ""))
                        .lineLimit(1)
                }
            }
            .font(DesignTokens.QuietList.rowMetaFont)
            .foregroundStyle(DesignTokens.Palette.textTertiary)
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
