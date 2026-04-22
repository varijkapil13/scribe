import SwiftUI

/// Design tokens for Scribe's native macOS UI.
///
/// Everything is derived from the system palette and SF Pro so light/dark
/// mode, high-contrast mode, and Dynamic Type work automatically. Consumers
/// should reference these tokens instead of hardcoding values.
enum DesignTokens {

    // MARK: - Spacing (4/8 rhythm)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Corner radii

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    // MARK: - Semantic colors

    enum Palette {
        /// Accent bar / chip for the user's own audio.
        static let speakerYou: Color = .blue
        /// Accent bar / chip for remote participants (system audio).
        static let speakerRemote: Color = .teal
        /// Fallback for speakers that aren't classified.
        static let speakerOther: Color = .gray

        /// Recording state accent.
        static let recording: Color = .red
        /// Paused state accent.
        static let paused: Color = .orange

        /// Action item priority.
        static let priorityHigh: Color = .red
        static let priorityMedium: Color = .orange
        static let priorityLow: Color = .blue

        /// Surface tokens — derived from AppKit so themes track automatically.
        static let surface = Color(nsColor: .windowBackgroundColor)
        static let surfaceElevated = Color(nsColor: .controlBackgroundColor)
        static let divider = Color(nsColor: .separatorColor)
    }
}

// MARK: - Color helpers

extension Color {

    /// Returns the accent tint associated with a speaker label. Matches the
    /// strings produced by ``SpeechRecognizerEngine`` ("you", "remote").
    static func speakerTint(for speaker: String) -> Color {
        switch speaker.lowercased() {
        case "you":    return DesignTokens.Palette.speakerYou
        case "remote": return DesignTokens.Palette.speakerRemote
        default:       return DesignTokens.Palette.speakerOther
        }
    }
}

// MARK: - View modifiers

extension View {

    /// Wraps the view in a card-style container with an accent bar on the
    /// leading edge. Used by the Insights tab and summary blocks.
    func accentCard(tint: Color) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                self
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }
}
