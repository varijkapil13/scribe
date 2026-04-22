import SwiftUI

/// Small coloured capsule indicating action-item priority. The tint matches
/// ``DesignTokens.Palette`` so it stays consistent with the rest of the UI.
struct PriorityBadge: View {
    let priority: ActionItem.Priority

    var body: some View {
        Text(priority.rawValue.uppercased())
            .font(.system(.caption2, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.25), lineWidth: 0.5)
            )
    }

    private var tint: Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        }
    }
}

/// A pill-shaped chip used for topics, key phrases, or tags. Uses a tinted
/// background that blends with the window chrome in both light and dark mode.
struct TagChip: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
    }
}

/// A compact capsule showing which speaker produced a segment.
struct SpeakerChip: View {
    let speaker: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .fill(Color.speakerTint(for: speaker))
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.system(.caption2, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var displayName: String {
        switch speaker.lowercased() {
        case "you":    return "You"
        case "remote": return "Remote"
        default:       return speaker.capitalized
        }
    }
}
