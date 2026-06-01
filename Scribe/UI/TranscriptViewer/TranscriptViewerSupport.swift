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
/// running Differentiate Without Color. Mirrors the speaker strings produced by
/// `SpeechRecognizerEngine` ("you", "remote").
enum SpeakerGlyph {
    static func symbol(for speaker: String) -> String {
        switch speaker.lowercased() {
        case "you":    return "person.fill"
        case "remote": return "person.wave.2.fill"
        default:       return "person"
        }
    }
}

// MARK: - Reduce-motion / reduce-transparency gated styling

/// Local design helpers for the transcript reader.
///
/// The shared Phase-0 substrate (motion springs, `scribeGlass`, contrast-aware
/// borders) is not present on this branch, so these mirror the same
/// accessibility contracts locally: every animation degrades to *instant*
/// under Reduce Motion, every material degrades to a *solid* fill under Reduce
/// Transparency / Increase Contrast, and hairline borders strengthen under
/// Increase Contrast. Scoped to the transcript viewer to avoid touching
/// spine-owned tokens.
enum ReaderStyle {

    /// Crisp, high-damping spring used for tab-underline + reveal moments.
    /// Resolved to `nil` under Reduce Motion so callers can skip the animation
    /// entirely (an instant change).
    static func spring(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }

    /// A gentle fade used to reveal freshly generated AI content. `nil` (no
    /// animation) under Reduce Motion.
    static func reveal(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: DesignTokens.Motion.standard)
    }

    /// Contrast-aware hairline border opacity. Matches the Phase-0 contract:
    /// ~0.06 normally, strengthening toward ~0.22 under Increase Contrast.
    static func borderOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.22 : 0.06
    }
}

extension View {

    /// Animate `value` changes with a reader spring, automatically gated on
    /// Reduce Motion. Pass the environment's `accessibilityReduceMotion`.
    func readerAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(ReaderStyle.spring(reduceMotion: reduceMotion), value: value)
    }

    /// Backs a transient surface (sheet, popover, HUD) with glass that collapses
    /// to a solid elevated fill under Reduce Transparency / Increase Contrast.
    /// Never use behind editable text or primary content panes.
    @ViewBuilder
    func readerGlassBackground(reduceTransparency: Bool,
                               contrast: ColorSchemeContrast,
                               cornerRadius: CGFloat = DesignTokens.Radius.lg) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            background(DesignTokens.Palette.surfaceElevated, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// A contrast-aware hairline border for cards/surfaces, strengthening under
    /// Increase Contrast so the edge stays legible.
    func readerCardBorder(_ contrast: ColorSchemeContrast,
                          cornerRadius: CGFloat = DesignTokens.Radius.md) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(ReaderStyle.borderOpacity(contrast)), lineWidth: 1)
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
