import SwiftUI

/// One transcript segment: speaker name and timestamp on a quiet meta line, the
/// text below in the reading serif. The playing segment lifts onto a raised card.
struct SegmentView: View {

    let segment: Segment
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    /// Highlights the row as the one currently playing back.
    var isCurrent: Bool = false
    /// When set (the session has audio), the timestamp becomes a button that
    /// plays the recording from this segment.
    var onTimestampTap: (() -> Void)? = nil
    /// Resolved speaker display name (session rename / reassignment / global
    /// "you" name). `nil` falls back to the built-in "You" / "Remote".
    var speakerName: String? = nil

    @State private var showAddToVocabulary = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.scribeAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            if isSelecting {
                Button(action: { onToggleSelection?() }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? accent : DesignTokens.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel(isSelected ? "Deselect segment" : "Select segment")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    speakerMarker
                    Text(speakerDisplayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .lineLimit(1)
                    timestamp
                    Spacer(minLength: 0)
                }

                Text(segment.text)
                    .font(DesignTokens.Typography.reading)
                    .lineSpacing(5)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.hairline, lineWidth: 1)
                .opacity(isCurrent ? 1 : 0)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerDisplayName) at \(segment.formattedTimestamp): \(segment.text)")
        .contextMenu {
            Button("Add to Vocabulary…") { showAddToVocabulary = true }
        }
        .sheet(isPresented: $showAddToVocabulary) {
            AddToVocabularySheet(segmentText: segment.text)
        }
    }

    private var rowFill: Color {
        if isCurrent { return DesignTokens.Palette.raised }
        if isSelecting && isSelected { return DesignTokens.Palette.selectionFill }
        return .clear
    }

    @ViewBuilder
    private var speakerMarker: some View {
        if differentiateWithoutColor {
            Image(systemName: SpeakerGlyph.symbol(for: effectiveSpeakerKey))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(Color.speakerTint(for: effectiveSpeakerKey).opacity(0.7))
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
        }
    }

    /// Speaker key after any per-segment reassignment; drives tint + glyph.
    private var effectiveSpeakerKey: String {
        SpeakerNameResolver.effectiveKey(for: segment)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let onTimestampTap {
            Button(action: onTimestampTap) {
                Text(segment.formattedTimestamp)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            .accessibilityLabel("Play from \(segment.formattedTimestamp)")
        } else {
            Text(segment.formattedTimestamp)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        }
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
