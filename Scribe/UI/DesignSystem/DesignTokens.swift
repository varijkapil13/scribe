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
        static let eyebrow = Font.system(.caption, weight: .semibold)
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
    /// leading edge. Used by the Insights tab and summary blocks. The
    /// hairline border strengthens automatically under Increase Contrast.
    func accentCard(tint: Color) -> some View {
        modifier(AccentCardModifier(tint: tint))
    }

    /// Elevated card treatment: rounded, hairline-bordered, softly shadowed.
    /// Prefer this over raw `.background(.surfaceElevated)` for any content
    /// block the user should perceive as lifting off the page. The border is
    /// contrast-aware (Increase Contrast bumps the hairline to stay legible).
    func cardStyle(padding: CGFloat = DesignTokens.Spacing.lg,
                   radius: CGFloat = DesignTokens.Radius.lg,
                   elevation: DesignTokens.ShadowStyle = DesignTokens.Shadow.hairline) -> some View {
        modifier(CardStyleModifier(padding: padding, radius: radius, elevation: elevation))
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

// MARK: - Card modifiers (contrast-aware)

/// Backing modifier for `accentCard(tint:)`. A `ViewModifier` (rather than a
/// plain `View` extension) so it can read `colorSchemeContrast` and strengthen
/// the hairline border under Increase Contrast.
private struct AccentCardModifier: ViewModifier {
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                content
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
        )
    }
}

/// Backing modifier for `cardStyle(...)`.
private struct CardStyleModifier: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat
    let elevation: DesignTokens.ShadowStyle
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
            )
            .shadow(color: .black.opacity(elevation.opacity),
                    radius: elevation.radius,
                    x: 0, y: elevation.y)
    }
}

// MARK: - Phase 0: Motion springs + the single reduce-motion gate

extension DesignTokens.Motion {
    /// Crisp, high-damping slide for panels, selection, and detail swaps.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Celebratory bounce — reserved for moments like task-complete /
    /// recording-saved, never for routine transitions.
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
    /// Gentle push/pop for spatial card navigation.
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.9)

    /// The single reduce-motion gate. Returns `nil` (an instant change) when
    /// Reduce Motion is on, so every spring/spatial transition degrades
    /// cleanly. Usage: `withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) { … }`.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct ScribeAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(DesignTokens.Motion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Applies `animation` keyed to `value`, automatically dropping to an
    /// instant change under Reduce Motion. Prefer this over a raw
    /// `.animation(_:value:)` for any spring/spatial motion.
    func scribeAnimation<V: Equatable>(_ animation: Animation = DesignTokens.Motion.snappy,
                                       value: V) -> some View {
        modifier(ScribeAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Phase 0: Glass / material tokens (mandatory fallbacks)

extension DesignTokens {
    /// The three legitimate translucent chrome surfaces. Content panes (note
    /// editor, transcript body, task rows) must NOT use these — glass is
    /// reserved for transient chrome (the IINA/Arc discipline).
    enum Surface {
        enum Role { case chrome, sidebar, hud }
    }
}

private struct GlassBackgroundModifier<S: Shape>: ViewModifier {
    let role: DesignTokens.Surface.Role
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background(style, in: shape)
    }

    /// Collapses glass to a solid fill when the user needs legibility
    /// (Reduce Transparency or Increase Contrast).
    private var style: AnyShapeStyle {
        if reduceTransparency || contrast == .increased {
            return AnyShapeStyle(DesignTokens.Palette.solidSurface(for: role))
        }
        switch role {
        case .chrome:  return AnyShapeStyle(.bar)
        case .sidebar: return AnyShapeStyle(.thinMaterial)
        case .hud:     return AnyShapeStyle(.regularMaterial)
        }
    }
}

extension View {
    /// Backs a transient chrome surface (command palette, floating recorder,
    /// inspector, popover) with the role's material, collapsing to a solid
    /// fill under Reduce Transparency / Increase Contrast. The single
    /// enforcement point for "glass floats, content is solid".
    func scribeGlass(_ role: DesignTokens.Surface.Role,
                     in shape: some Shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)) -> some View {
        modifier(GlassBackgroundModifier(role: role, shape: shape))
    }
}

// MARK: - Phase 0: Contrast-aware tonal system + non-color companions

extension DesignTokens.Palette {
    enum FillLevel { case hover, selected, strong }

    /// Hairline card/divider border that strengthens under Increase Contrast
    /// (the flat 0.06 wash drops below WCAG in dark mode / high contrast).
    static func cardBorder(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.20 : 0.06)
    }

    /// Neutral interactive fill (hover / selection / pressed) that scales up
    /// under Increase Contrast. Replaces scattered `.opacity(0.06/0.08/0.12)`.
    static func fill(_ level: FillLevel, contrast: ColorSchemeContrast = .standard) -> Color {
        let base: Double
        switch level {
        case .hover:    base = 0.06
        case .selected: base = 0.10
        case .strong:   base = 0.15
        }
        return Color.primary.opacity(base * (contrast == .increased ? 1.8 : 1.0))
    }

    /// Accent-tinted interactive fill derived from the resolved theme accent.
    static func accentFill(_ level: FillLevel, accent: Color, contrast: ColorSchemeContrast = .standard) -> Color {
        let base: Double
        switch level {
        case .hover:    base = 0.10
        case .selected: base = 0.16
        case .strong:   base = 0.24
        }
        return accent.opacity(base * (contrast == .increased ? 1.5 : 1.0))
    }

    /// Solid fallback fill for a glass role under Reduce Transparency.
    static func solidSurface(for role: DesignTokens.Surface.Role) -> Color {
        switch role {
        case .sidebar:      return surfaceSunken
        case .chrome, .hud: return surfaceElevated
        }
    }

    // SF Symbol companions so meaning survives Differentiate-Without-Color.
    static let prioritySymbolHigh = "exclamationmark.3"
    static let prioritySymbolMedium = "exclamationmark.2"
    static let prioritySymbolLow = "exclamationmark"
    static let recordingSymbol = "record.circle.fill"
    static let pausedSymbol = "pause.circle.fill"
    static let idleSymbol = "record.circle"
}

extension Color {
    /// SF Symbol companion to `speakerTint(for:)` so speaker identity in the
    /// live feed / transcript survives Differentiate-Without-Color.
    static func speakerSymbol(for speaker: String) -> String {
        switch speaker.lowercased() {
        case "you":    return "mic.fill"
        case "remote": return "speaker.wave.2.fill"
        default:       return "person.fill"
        }
    }
}

// MARK: - Phase 0: Scaled editorial serif (Dynamic Type)

private struct ScaledSerifFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(baseSize: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight) {
        self._size = ScaledMetric(wrappedValue: baseSize, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .serif))
    }
}

extension View {
    /// Editorial serif display (~44pt) that scales with the system Larger
    /// Text setting — same look at the default size, no longer a hard
    /// accessibility wall. Drop-in for `.font(DesignTokens.Typography.display)`.
    func scribeDisplay() -> some View {
        modifier(ScaledSerifFont(baseSize: 44, relativeTo: .largeTitle, weight: .semibold))
    }
    /// Scaled serif title (~34pt), relative to `.title`.
    func scribeTitle1() -> some View {
        modifier(ScaledSerifFont(baseSize: 34, relativeTo: .title, weight: .semibold))
    }
    /// Scaled serif secondary title (~28pt), relative to `.title2`.
    func scribeTitle2() -> some View {
        modifier(ScaledSerifFont(baseSize: 28, relativeTo: .title2, weight: .semibold))
    }
}

// MARK: - Phase 0: Theme accent rail (chrome-only)

private struct ScribeAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    /// The resolved chrome accent: a user-selected accent, or the active
    /// Space/Project tint, falling back to the system accent. Tints chrome
    /// only (sidebar selection, command bar, record pill) — never content.
    var scribeAccent: Color {
        get { self[ScribeAccentKey.self] }
        set { self[ScribeAccentKey.self] = newValue }
    }
}
