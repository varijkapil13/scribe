import SwiftUI

/// IINA-style floating glass controller for a live recording session: a compact
/// capsule carrying the elapsed timer, a level meter, pause/stop, an expand
/// chevron, and a non-color state glyph.
///
/// It is fully self-contained — the spine places it as a `MainWindowView`
/// `.overlay`, passing the shared `audioManager`/`appState` plus closures for
/// pause/stop/expand. (See `integrationHooksForSpine`.)
///
/// Auto-hide behavior (the IINA discipline):
/// - Hidden on idle with **hysteresis** — separate show/hide thresholds and a
///   minimum dwell (~2.5 s) so it never flickers.
/// - Stays visible while hovered or while one of its controls holds focus.
/// - **Permanently visible** under Reduce Motion or while VoiceOver is running,
///   so motion-sensitive and assistive-tech users always have the transport.
/// - Placement is user-controlled via `@AppStorage("liveControllerPlacement")`
///   (floating bottom-trailing / docked bottom-center).
struct LiveControllerOverlay: View {

    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject var appState: AppState

    /// Toggle pause / resume.
    var onPauseToggle: () -> Void
    /// Stop the session.
    var onStop: () -> Void
    /// Expand back to the full live view.
    var onExpand: () -> Void

    @AppStorage("liveControllerPlacement") private var placementRaw: String = Placement.floating.rawValue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent

    @State private var isHovering = false
    @FocusState private var controlFocused: Bool
    @State private var isVisible = true
    @State private var lastActivityAt: Date = .init()
    /// Hysteresis dwell timer — re-evaluates visibility on a slow cadence so the
    /// controller stays put for the minimum dwell before fading.
    @State private var dwellTask: Task<Void, Never>?

    // MARK: - Placement

    enum Placement: String, CaseIterable {
        case floating   // bottom-trailing, inset
        case docked     // bottom-center

        var alignment: Alignment {
            switch self {
            case .floating: return .bottomTrailing
            case .docked:   return .bottom
            }
        }
    }

    private var placement: Placement { Placement(rawValue: placementRaw) ?? .floating }

    /// The controller is only meaningful during a live session.
    private var isActive: Bool { appState.isTranscribing }

    /// Whether motion/AT requirements force the controller to stay shown.
    private var pinnedVisible: Bool { reduceMotion || voiceOverEnabled }

    private var shouldShow: Bool {
        guard isActive else { return false }
        if pinnedVisible { return true }
        return isVisible || isHovering || controlFocused
    }

    var body: some View {
        ZStack(alignment: placement.alignment) {
            Color.clear
            if shouldShow {
                capsule
                    .padding(placement == .floating ? DesignTokens.Spacing.xl : DesignTokens.Spacing.lg)
                    .transition(controllerTransition)
            }
        }
        .allowsHitTesting(shouldShow)
        .scribeAnimation(.snappy, value: shouldShow)
        .onAppear { restartDwell() }
        .onDisappear { dwellTask?.cancel() }
        .onChange(of: isActive) { _, active in
            if active { isVisible = true; bumpActivity() }
        }
        // Re-show + reset the dwell whenever audio activity rises — speech onset
        // is the natural cue to bring the transport back.
        .onChange(of: audioManager.inputLevel) { _, level in
            if level > showLevelThreshold { bumpActivity() }
        }
        .onChange(of: audioManager.isPaused) { _, _ in bumpActivity() }
    }

    // MARK: - Capsule

    private var capsule: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            stateGlyph

            Text(formattedDuration)
                .font(.system(.callout, design: .monospaced).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .accessibilityLabel("Elapsed \(formattedDuration)")

            LevelMeterView(level: audioManager.inputLevel,
                           tint: accent,
                           barCount: 8,
                           sourceLabel: "Input")
                .frame(width: 40)

            Divider().frame(height: 18)

            pauseButton
            stopButton
            expandButton
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .scribeGlass(.hud, in: Capsule())
        .overlay(
            Capsule().strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
        )
        .shadow(color: .black.opacity(DesignTokens.Shadow.medium.opacity),
                radius: DesignTokens.Shadow.medium.radius,
                y: DesignTokens.Shadow.medium.y)
        .onHover { hovering in
            isHovering = hovering
            if hovering { bumpActivity() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording controller")
    }

    /// Shared live-session state, so the controller's glyph/tint classify the
    /// session identically to `LiveSessionView` and the in-note pane.
    private var status: LiveFeedStatus {
        .resolve(isTranscribing: appState.isTranscribing,
                 isPaused: audioManager.isPaused)
    }

    /// Non-color state glyph (record / pause) so meaning survives
    /// Differentiate Without Color and reads at a glance.
    private var stateGlyph: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(status.tint)
            .symbolEffect(.pulse, isActive: !audioManager.isPaused && !reduceMotion && !differentiateWithoutColor)
            .accessibilityLabel(status.label)
    }

    private var pauseButton: some View {
        Button(action: { onPauseToggle(); bumpActivity() }) {
            Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .focused($controlFocused)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(audioManager.isPaused ? "Resume recording" : "Pause recording")
        .accessibilityHint("Space")
    }

    private var stopButton: some View {
        Button(action: { onStop() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.recording)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Command period")
    }

    private var expandButton: some View {
        Button(action: { onExpand(); bumpActivity() }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand to full live view")
    }

    // MARK: - Auto-hide hysteresis

    /// Rises high enough to *show* the controller (speech onset).
    private let showLevelThreshold: Float = 0.12
    /// Minimum time the controller stays up after the last activity.
    private let minDwell: TimeInterval = 2.5

    private func bumpActivity() {
        lastActivityAt = Date()
        if !isVisible { isVisible = true }
        restartDwell()
    }

    /// A single long-lived poll that fades the controller once the dwell has
    /// elapsed with no hover/focus/activity. Cheaper than a repeating Timer and
    /// naturally cancels on disappear. No-ops while pinned visible.
    private func restartDwell() {
        dwellTask?.cancel()
        guard !pinnedVisible else { isVisible = true; return }
        dwellTask = Task { @MainActor in
            while !Task.isCancelled {
                let idle = Date().timeIntervalSince(lastActivityAt)
                let remaining = minDwell - idle
                if remaining <= 0 {
                    if !isHovering && !controlFocused {
                        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                            isVisible = false
                        }
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(min(remaining, 0.5)))
            }
        }
    }

    private var controllerTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: placement == .docked ? .bottom : .trailing)
            .combined(with: .opacity)
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        LiveFeedStatus.formattedElapsed(audioManager.recordingDuration)
    }
}
