import SwiftUI

/// A compact live-status pill for the main window toolbar. Shows a coloured
/// dot + state label + monospaced elapsed timer while recording. Collapses
/// to a subtle idle form when not recording.
///
/// Matches the editorial/minimalist direction: muted when idle, confident
/// but restrained when live (small pulsing dot + tabular digits, no flashing
/// backgrounds or jittery micro-animations).
struct RecordingStatusPill: View {

    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject var appState: AppState

    @State private var pulsePhase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            statusDot
            Text(label)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(textTint)

            if appState.isTranscribing {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(formattedDuration)
                    .font(.system(.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(background)
        )
        .overlay(
            Capsule()
                .strokeBorder(border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // State changes ride the shared snappy spring, auto-gated to instant
        // under Reduce Motion via `.scribeAnimation`.
        .scribeAnimation(.snappy, value: appState.isTranscribing)
        .scribeAnimation(.snappy, value: audioManager.isPaused)
        .onAppear { if !reduceMotion { startPulse() } }
    }

    // MARK: - Dot with live pulse

    @ViewBuilder
    private var statusDot: some View {
        if differentiateWithoutColor {
            // Non-color cue: a distinct glyph per state so meaning doesn't
            // rely on red-vs-amber-vs-gray alone (Differentiate Without Color).
            Image(systemName: stateSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
        } else {
            ZStack {
                // Outer halo — only visible while recording + not paused + not reduced motion.
                Circle()
                    .fill(tint.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(showHalo ? (0.9 + pulsePhase * 0.5) : 0.6)
                    .opacity(showHalo ? (0.6 - pulsePhase * 0.6) : 0)
                    .animation(.easeOut(duration: 1.4), value: pulsePhase)

                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)
        }
    }

    private var stateSymbol: String {
        if audioManager.isPaused { return DesignTokens.Palette.pausedSymbol }
        if appState.isTranscribing { return DesignTokens.Palette.recordingSymbol }
        return DesignTokens.Palette.idleSymbol
    }

    // MARK: - State derivations

    private var tint: Color {
        if audioManager.isPaused { return DesignTokens.Palette.paused }
        if appState.isTranscribing { return DesignTokens.Palette.recording }
        return .secondary
    }

    private var textTint: Color {
        if audioManager.isPaused { return DesignTokens.Palette.paused }
        if appState.isTranscribing { return DesignTokens.Palette.recording }
        return .secondary
    }

    private var background: Color {
        if appState.isTranscribing {
            return tint.opacity(0.12)
        }
        return DesignTokens.Palette.surfaceElevated.opacity(0.6)
    }

    private var border: Color {
        if appState.isTranscribing {
            return tint.opacity(0.25)
        }
        return DesignTokens.Palette.cardBorder
    }

    private var label: String {
        if audioManager.isPaused { return "Paused" }
        if appState.isTranscribing { return "Recording" }
        return "Idle"
    }

    private var showHalo: Bool {
        appState.isTranscribing && !audioManager.isPaused && !reduceMotion
    }

    private var formattedDuration: String {
        let total = Int(audioManager.recordingDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var accessibilityLabel: String {
        if audioManager.isPaused { return "Recording paused, \(formattedDuration)" }
        if appState.isTranscribing { return "Recording, \(formattedDuration)" }
        return "Idle"
    }

    // MARK: - Pulse driver

    private func startPulse() {
        // Drive a simple 0 → 1 → 0 cycle with SwiftUI animation. The effect is
        // only rendered while `showHalo` is true, so when the user pauses or
        // stops we stop paying for the layer work.
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulsePhase = 1
        }
    }
}
