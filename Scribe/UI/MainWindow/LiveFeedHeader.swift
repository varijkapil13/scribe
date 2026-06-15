import SwiftUI

/// Shared "this is one live session" identity for the three live renderings —
/// `LiveSessionView`, `NoteLiveRecordingPane`, and `LiveControllerOverlay`.
///
/// Before this existed each view derived its own state label, tint, glyph, and
/// re-implemented the same `MM:SS` / `H:MM:SS` formatter (four copies). They
/// drifted subtly — one said "RECORDING", another "Recording"; the in-note pane
/// had no elapsed timer at all. `LiveFeedStatus` is the single source for the
/// state→presentation mapping and the elapsed-time formatter, and
/// `LiveFeedHeader` is the compact "● Recording · 04:12" line the small surfaces
/// (in-note pane) render so they read identically to the full view.
///
/// Everything here is pure (no `@EnvironmentObject`, no timers): callers pass in
/// the current state and the live `recordingDuration` from the shared
/// `AudioSessionManager`, so there is never a second clock.
enum LiveFeedStatus: Equatable {
    case ready
    case recording
    case paused

    /// Maps `appState.isTranscribing` + `audioManager.isPaused` onto the status,
    /// so every call site classifies state the same way.
    static func resolve(isTranscribing: Bool, isPaused: Bool) -> LiveFeedStatus {
        if isPaused { return .paused }
        if isTranscribing { return .recording }
        return .ready
    }

    /// Title-case label used in the compact header / status line.
    var label: String {
        switch self {
        case .ready:     return "Ready"
        case .recording: return "Recording"
        case .paused:    return "Paused"
        }
    }

    /// Uppercase eyebrow label used by the full view's hero.
    var eyebrow: String { label.uppercased() }

    var tint: Color {
        switch self {
        case .ready:     return .secondary
        case .recording: return DesignTokens.Palette.recording
        case .paused:    return DesignTokens.Palette.paused
        }
    }

    /// Non-color state glyph so meaning survives Differentiate Without Color.
    var symbol: String {
        switch self {
        case .ready:     return DesignTokens.Palette.idleSymbol
        case .recording: return DesignTokens.Palette.recordingSymbol
        case .paused:    return DesignTokens.Palette.pausedSymbol
        }
    }

    /// The canonical live elapsed-time formatter shared by all three views:
    /// `"MM:SS"` under an hour, `"H:MM:SS"` (non-padded hours) beyond. Pure and
    /// unit-tested — see `LiveFeedHeaderTests`.
    static func formattedElapsed(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Compact status line — a coloured state dot (or non-color glyph) followed by
/// "Recording · 04:12". Used by the smaller live surfaces (the in-note pane and,
/// conceptually, anything that needs the live session's identity in one line).
/// The full `LiveSessionView` hero renders a larger bespoke layout but draws its
/// label / tint / symbol / elapsed string from the same `LiveFeedStatus`.
struct LiveFeedHeader: View {

    let status: LiveFeedStatus
    /// Live elapsed seconds, sourced from `AudioSessionManager.recordingDuration`.
    let duration: TimeInterval

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var elapsed: String { LiveFeedStatus.formattedElapsed(duration) }

    private var showsElapsed: Bool {
        switch status {
        case .recording, .paused: return true
        case .ready:              return false
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            statusDot

            Text(status.label)
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.5)
                .foregroundStyle(status.tint)

            if showsElapsed {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(elapsed)
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusDot: some View {
        if differentiateWithoutColor {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(status.tint)
                .frame(width: 8, height: 8)
        }
    }

    private var accessibilityLabel: String {
        guard showsElapsed else { return status.label }
        return "\(status.label), \(elapsed)"
    }
}
