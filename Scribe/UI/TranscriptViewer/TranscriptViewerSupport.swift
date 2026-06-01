import SwiftUI
import AppKit
import FoundationModels

// MARK: - Apple Intelligence availability

/// A UI-facing snapshot of whether on-device Apple Intelligence (Foundation
/// Models) can be used right now. The intelligence engines
/// (`MeetingSummarizer`) already gate on `SystemLanguageModel.default
/// .availability` and throw `IntelligenceError.notAvailable` — this mirrors
/// that gate so the reader can render a calm "unavailable on this Mac" state
/// *before* the user taps Generate, rather than surfacing it only as an error.
///
/// Kept deliberately small and `Sendable` so it can be read from any actor.
enum AppleIntelligenceAvailability: Equatable, Sendable {
    /// The model is ready to use.
    case available
    /// The model exists but isn't usable yet (downloading, disabled, etc.).
    case unavailable(reason: String)

    /// Queries the system model. Cheap — `SystemLanguageModel.default` is a
    /// shared accessor and `availability` is a synchronous property.
    static var current: AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// A short, human, non-technical reason for the unavailable banner. The raw
    /// `UnavailableReason` enum stringifies to terse camelCase, so we map the
    /// known cases to copy that reads well to someone who isn't an engineer.
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to generate summaries and insights."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. Try again in a few minutes."
        @unknown default:
            return "Apple Intelligence isn't available on this Mac right now."
        }
    }
}

// MARK: - Non-color speaker cue

/// SF Symbol that distinguishes a speaker *without relying on color*, for users
/// running Differentiate Without Color. Thin alias over the canonical Phase-0
/// `Color.speakerSymbol(for:)` so the glyph stays consistent app-wide.
enum SpeakerGlyph {
    static func symbol(for speaker: String) -> String {
        Color.speakerSymbol(for: speaker)
    }
}

// MARK: - Reduce-motion / reduce-transparency gated styling

/// Transcript-reader styling aliases. Thin wrappers over the shared Phase-0
/// substrate (spring motion, `scribeGlass`, contrast-aware borders) so the
/// reader's chrome matches the rest of the redesign while keeping these
/// call-site-friendly names. The a11y contracts (instant under Reduce Motion,
/// solid under Reduce Transparency / Increase Contrast, stronger hairlines
/// under Increase Contrast) all come from the canonical tokens.
enum ReaderStyle {

    /// Crisp, high-damping spring for tab-underline + reveal moments; `nil`
    /// (instant) under Reduce Motion via the canonical gate. Fully qualified so
    /// it binds to our tuned token, not SwiftUI's built-in `Animation.snappy`.
    static func spring(reduceMotion: Bool) -> Animation? {
        DesignTokens.Motion.resolve(DesignTokens.Motion.snappy, reduceMotion: reduceMotion)
    }

    /// Gentle reveal for freshly generated AI content; `nil` under Reduce Motion.
    static func reveal(reduceMotion: Bool) -> Animation? {
        DesignTokens.Motion.resolve(DesignTokens.Motion.gentle, reduceMotion: reduceMotion)
    }
}

extension View {

    /// Animate `value` changes with the reader spring, gated on Reduce Motion.
    func readerAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(ReaderStyle.spring(reduceMotion: reduceMotion), value: value)
    }

    /// Glass backing for a transient reader surface — routes to the canonical
    /// `scribeGlass(.hud)`, which collapses to a solid fill under Reduce
    /// Transparency / Increase Contrast. (Params kept for call-site
    /// compatibility; the canonical helper reads the environment itself.)
    func readerGlassBackground(reduceTransparency: Bool,
                               contrast: ColorSchemeContrast,
                               cornerRadius: CGFloat = DesignTokens.Radius.lg) -> some View {
        scribeGlass(.hud, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Contrast-aware hairline border via the canonical `Palette.cardBorder`.
    func readerCardBorder(_ contrast: ColorSchemeContrast,
                          cornerRadius: CGFloat = DesignTokens.Radius.md) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
        )
    }
}

// MARK: - Shimmer / skeleton

/// A reduce-motion-aware skeleton placeholder used while AI content generates.
///
/// Renders soft rounded bars. Under Reduce Motion it shows a static, dimmed
/// placeholder (no sweeping highlight); otherwise a slow shimmer sweeps across.
/// Marked `.accessibilityHidden` because the surrounding view announces the
/// generation state to VoiceOver.
struct ShimmerPlaceholder: View {
    /// Relative bar widths (0…1 of available width) to vary the rhythm.
    var lineWidths: [CGFloat] = [1.0, 0.92, 0.74, 0.96, 0.55]
    var lineHeight: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, fraction in
                GeometryReader { geo in
                    Capsule()
                        .fill(baseFill)
                        .frame(width: geo.size.width * fraction)
                        .overlay(alignment: .leading) {
                            if !reduceMotion {
                                Capsule()
                                    .fill(highlight)
                                    .frame(width: geo.size.width * fraction * 0.4)
                                    .offset(x: geo.size.width * fraction * phase)
                                    .blendMode(.plusLighter)
                                    .mask(Capsule().frame(width: geo.size.width * fraction))
                            }
                        }
                }
                .frame(height: lineHeight)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
        .accessibilityHidden(true)
    }

    private var baseFill: Color {
        Color.primary.opacity(contrast == .increased ? 0.16 : 0.09)
    }

    private var highlight: Color {
        Color.primary.opacity(0.12)
    }
}

// MARK: - Generation skeleton

/// The "AI is working" state for the summary / action-item / insight tabs.
///
/// Shows a small spinner + caption (which VoiceOver reads as the live status,
/// reinforced by the explicit announcement the view model posts) above a
/// reduce-motion-aware shimmer skeleton standing in for the text that's about
/// to appear. This reads as deliberate craft rather than a bare spinner.
struct GenerationSkeleton: View {
    let title: String
    var lineWidths: [CGFloat] = [1.0, 0.92, 0.74, 0.96, 0.55]

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ShimmerPlaceholder(lineWidths: lineWidths)
                .padding(DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(DesignTokens.Palette.surfaceElevated)
                )
                .readerCardBorder(contrast)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .top)
        // VoiceOver hears one calm status line; the shimmer itself is hidden.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Apple Intelligence unavailable state

/// Calm, non-alarming state shown when on-device Apple Intelligence can't be
/// used. Distinct from an *error* (which implies a retryable failure): this is
/// a capability gap, so it explains rather than offers "Try Again".
struct IntelligenceUnavailableView: View {
    let reason: String

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: DesignTokens.Spacing.xs) {
                Text("Apple Intelligence unavailable")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .textSelection(.enabled)
            }

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, DesignTokens.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Intelligence unavailable. \(reason)")
    }
}

// MARK: - Reveal modifier

/// Reveals freshly generated content with a tasteful fade + slight rise, gated
/// on Reduce Motion (where it becomes an instant appearance). Re-runs whenever
/// `token` changes — i.e. each time the view model lands a new generation — by
/// keying the identity so the transition fires on the new content.
struct RevealModifier: ViewModifier {
    let token: Int
    let reduceMotion: Bool

    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 6)
            .onAppear { applyReveal() }
            .onChange(of: token) {
                revealed = false
                applyReveal()
            }
    }

    private func applyReveal() {
        if reduceMotion {
            revealed = true
        } else {
            withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                revealed = true
            }
        }
    }
}
