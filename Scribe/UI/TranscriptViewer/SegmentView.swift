import SwiftUI

/// Renders a single transcript segment as a chat-style row: speaker chip + timestamp
/// on one line, the transcribed text below with a tinted vertical accent bar on the
/// leading edge. The accent colour matches the speaker (`You` vs `Remote`).
struct SegmentView: View {

    let segment: Segment
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            if isSelecting {
                Button(action: { onToggleSelection?() }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            // Vertical accent bar keyed to the speaker.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.speakerTint(for: segment.speaker))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .opacity(0.85)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    SpeakerChip(speaker: segment.speaker)
                    Text(segment.formattedTimestamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerDisplayName) at \(segment.formattedTimestamp): \(segment.text)")
    }

    private var speakerDisplayName: String {
        switch segment.speaker.lowercased() {
        case "you":    return "You"
        case "remote": return "Remote"
        default:       return segment.speaker
        }
    }
}
