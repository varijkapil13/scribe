import SwiftUI

/// Design tokens for Scribe's native macOS UI.
///
/// Everything is derived from the system palette and SF typography so light/
/// dark mode, high-contrast, Dynamic Type, and Reduce-Motion work
/// automatically. Consumers should reference these tokens instead of
/// hardcoding values — that's how the app stays visually coherent as
/// features grow.
///
/// Design direction: **editorial minimalism**. Oversized serif display
/// headlines, generous whitespace, muted chrome, colorful content only where
/// it's semantic (speaker tints, recording state). Think Granola / Things 3 /
/// Notes — not a generic AI dashboard.
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
        static let huge: CGFloat = 64
    }

    // MARK: - Corner radii

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - Typography

    /// Editorial type scale. Display sizes use the SF "New York" serif
    /// (`design: .serif`) for headlines; body/label use the system sans for
    /// native legibility. Body and numeric styles default to tabular figures
    /// so durations and counts don't jitter as digits change.
    enum Typography {
        /// Hero display used on the welcome empty state (~44pt, serif).
        static let display = Font.system(size: 44, weight: .semibold, design: .serif)
        /// Large editorial title used on transcript detail headers (~34pt).
        static let title1 = Font.system(size: 34, weight: .semibold, design: .serif)
        /// Secondary serif title, e.g. settings pane header (~28pt).
        static let title2 = Font.system(size: 28, weight: .semibold, design: .serif)
        /// Sans-serif section headline inside detail content.
        static let section = Font.system(.headline, weight: .semibold)
        /// Section / eyebrow label, small, letter-spaced. Pair with `.tracking`.
        static let eyebrow = Font.system(.caption2, weight: .semibold)
        /// Body copy for transcript text and summaries.
        static let body = Font.system(.body)
        /// Callout body for metadata strips.
        static let callout = Font.system(.callout)
        /// Monospaced, tabular-digit display for timers and durations.
        static let timer = Font.system(.title3, design: .monospaced).monospacedDigit()
        /// Small monospaced timestamp (transcript segments).
        static let timestamp = Font.system(.caption2, design: .monospaced).monospacedDigit()
    }

    // MARK: - Shadows

    /// Shadow tokens for elevated surfaces. Kept deliberately subtle — macOS
    /// content should feel weightless, not drop-shadowy.
    enum Shadow {
        static let hairline = ShadowStyle(radius: 1, y: 0.5, opacity: 0.06)
        static let soft     = ShadowStyle(radius: 6, y: 2,   opacity: 0.08)
        static let medium   = ShadowStyle(radius: 14, y: 4,  opacity: 0.10)
    }

    struct ShadowStyle {
        let radius: CGFloat
        let y: CGFloat
        let opacity: Double
    }

    // MARK: - Motion

    /// Standard motion durations. Short enough to feel responsive, long
    /// enough to read as animation — roughly aligned with Material's 150–300ms
    /// band. Used with `.easeOut` for entries and `.easeIn` for exits.
    enum Motion {
        static let fast: Double    = 0.15
        static let standard: Double = 0.24
        static let slow: Double    = 0.36
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

        /// Action-item priority.
        static let priorityHigh: Color = .red
        static let priorityMedium: Color = .orange
        static let priorityLow: Color = .blue

        /// Surface tokens — derived from AppKit so themes track automatically.
        static let surface = Color(nsColor: .windowBackgroundColor)
        static let surfaceElevated = Color(nsColor: .controlBackgroundColor)
        /// A slightly lifted surface used for sunken panels (transcript body
        /// background behind segments, side panels, etc.).
        static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)
        static let divider = Color(nsColor: .separatorColor)
        /// Hairline border used on elevated cards in both themes.
        static let cardBorder = Color.primary.opacity(0.06)
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
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
    }

    /// Elevated card treatment: rounded, hairline-bordered, softly shadowed.
    /// Prefer this over raw `.background(.surfaceElevated)` for any content
    /// block the user should perceive as lifting off the page.
    func cardStyle(padding: CGFloat = DesignTokens.Spacing.lg,
                   radius: CGFloat = DesignTokens.Radius.lg,
                   elevation: DesignTokens.ShadowStyle = DesignTokens.Shadow.hairline) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(elevation.opacity),
                    radius: elevation.radius,
                    x: 0, y: elevation.y)
    }

    /// Small uppercase eyebrow label ("TRANSCRIPT", "SUMMARY") used to
    /// section editorial content blocks without shouting.
    func eyebrowStyle(tint: Color = .secondary) -> some View {
        self
            .font(DesignTokens.Typography.eyebrow)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(tint)
    }
}
