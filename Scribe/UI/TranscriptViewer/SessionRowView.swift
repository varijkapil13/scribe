import SwiftUI

/// Row view for displaying a session summary in the transcript list sidebar.
struct SessionRowView: View {

    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(1)

            HStack {
                Text(session.createdAt, style: .date)
                    .font(.caption)
                Spacer()
                if let duration = session.durationSeconds {
                    Text(formattedDuration(duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !session.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(session.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Private Helpers

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
