import SwiftUI

/// View for rendering a single transcript segment with timestamp,
/// speaker label, and text.
struct SegmentView: View {

    let segment: Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(segment.formattedTimestamp)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Text(speakerDisplayName)
                    .font(.caption)
                    .bold()
                    .foregroundColor(speakerColor)
            }

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerDisplayName) at \(segment.formattedTimestamp): \(segment.text)")
    }

    // MARK: - Computed Properties

    /// Capitalizes known speaker labels for display.
    private var speakerDisplayName: String {
        switch segment.speaker.lowercased() {
        case "you":
            return "You"
        case "remote":
            return "Remote"
        default:
            return segment.speaker
        }
    }

    /// Returns a distinct color for known speaker roles.
    private var speakerColor: Color {
        switch segment.speaker.lowercased() {
        case "you":
            return .blue
        case "remote":
            return .green
        default:
            return .orange
        }
    }
}
