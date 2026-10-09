import SwiftUI

/// Renders a single transcript segment as a chat-style row: speaker chip + timestamp
/// on one line, the transcribed text below with a tinted vertical accent bar on the
/// leading edge. The accent colour matches the speaker (`You` vs `Remote`).
struct SegmentView: View {

    let segment: Segment
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    /// Resolved speaker display name (session rename / reassignment / global
    /// "you" name). `nil` falls back to the built-in "You" / "Remote".
    var speakerName: String? = nil

    @State private var showAddToVocabulary = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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
                .padding(.top, DesignTokens.Spacing.xs)
                .accessibilityLabel(isSelected ? "Deselect segment" : "Select segment")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            // Vertical accent bar keyed to the speaker.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.speakerTint(for: effectiveSpeakerKey))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .opacity(0.85)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    // Non-color speaker cue: a glyph supplements the tinted chip
                    // for users running Differentiate Without Color.
                    if differentiateWithoutColor {
                        Image(systemName: SpeakerGlyph.symbol(for: effectiveSpeakerKey))
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    SpeakerChip(speaker: effectiveSpeakerKey, name: speakerName)
                    Text(segment.formattedTimestamp)
                        .font(DesignTokens.Typography.timestamp)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Text(segment.text)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerDisplayName) at \(segment.formattedTimestamp): \(segment.text)")
        .contextMenu {
            Button("Add to Vocabulary…") { showAddToVocabulary = true }
        }
        .sheet(isPresented: $showAddToVocabulary) {
            AddToVocabularySheet(segmentText: segment.text)
        }
    }

    /// Speaker key after any per-segment reassignment; drives tint + glyph.
    private var effectiveSpeakerKey: String {
        SpeakerNameResolver.effectiveKey(for: segment)
    }

    private var speakerDisplayName: String {
        if let speakerName, !speakerName.isEmpty { return speakerName }
        switch effectiveSpeakerKey.lowercased() {
        case "you":    return "You"
        case "remote": return "Remote"
        default:       return effectiveSpeakerKey
        }
    }
}
