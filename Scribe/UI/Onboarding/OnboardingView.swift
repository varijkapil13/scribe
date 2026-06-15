import SwiftUI

/// First-run onboarding sheet. A calm, serif-voiced 4-step primer that:
/// 1. Welcomes and sets the tone.
/// 2. Primes Microphone access in context, showing a `LevelMeterView` reacting.
/// 3. Explains *when* system-audio (ScreenCaptureKit) is relevant — shown only
///    when the user intends to capture meetings.
/// 4. Previews the one-time speech-model download and teaches the global
///    Shift-Cmd-R record shortcut.
///
/// Gated by `@AppStorage("hasCompletedOnboarding")`. Skip and Escape bypass it.
/// Steps crossfade under Reduce Motion (no horizontal slide).
///
/// Built standalone — the spine presents it as a `.sheet`. (See
/// `integrationHooksForSpine`.)
struct OnboardingView: View {

    /// Bound to the presenting sheet so Skip / Done / Escape can dismiss it.
    @Binding var isPresented: Bool

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("captureSystemAudio") private var captureSystemAudio: Bool = true

    /// Drives the mic-test preview meter. When a real session isn't running we
    /// animate a gentle demo level so the meter visibly "breathes".
    @ObservedObject var audioManager: AudioSessionManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent

    @State private var stepIndex: Int = 0
    @State private var micGranted: Bool = false
    @State private var micRequestInFlight = false
    @State private var demoLevel: Float = 0
    @State private var demoTimer: Timer?

    private let steps: [Step] = Step.all

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DesignTokens.Spacing.xxl)

            Divider()

            footer
                .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: 520, height: 460)
        .background(DesignTokens.Palette.surface)
        .onAppear(perform: refreshMicStatus)
        .onChange(of: stepIndex) { _, _ in handleStepChange() }
        .onDisappear { stopDemo() }
        // Escape bypasses onboarding entirely.
        .onExitCommand { skip() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Scribe")
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Image(systemName: step.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(step.title)
                    .scribeTitle2()
                    .foregroundStyle(.primary)

                Text(step.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stepExtras

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(stepIndex)
        .transition(stepTransition)
        .scribeAnimation(.snappy, value: stepIndex)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title). \(step.body)")
    }

    /// Per-step interactive extras (mic primer meter, system-audio toggle, etc.).
    @ViewBuilder
    private var stepExtras: some View {
        switch step.kind {
        case .surfaces:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                surfaceRow(symbol: "waveform",
                           name: "Capture",
                           detail: "Record & transcribe conversations")
                surfaceRow(symbol: "doc.text",
                           name: "Notes",
                           detail: "A markdown notebook for your ideas")
                surfaceRow(symbol: "checklist",
                           name: "Tasks",
                           detail: "Keep your to-dos within reach")
            }

        case .microphone:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.md) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    LevelMeterView(level: previewLevel,
                                   tint: accent,
                                   barCount: 16,
                                   sourceLabel: "Microphone")
                        .frame(width: 120)
                    Spacer()
                }

                Button {
                    requestMic()
                } label: {
                    Label(micGranted ? "Microphone ready" : "Allow microphone access",
                          systemImage: micGranted ? "checkmark.circle.fill" : "mic.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(micGranted ? .green : accent)
                .disabled(micGranted || micRequestInFlight)
                .accessibilityHint(micGranted
                    ? "Microphone access already granted"
                    : "Opens the system microphone permission prompt")
            }

        case .systemAudio:
            Toggle(isOn: $captureSystemAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture system audio for meetings")
                        .font(.callout.weight(.medium))
                    Text("Turn this on to transcribe remote participants. You can change it any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(accent)

        case .recordShortcut:
            HStack(spacing: DesignTokens.Spacing.sm) {
                shortcutKeycap("⇧")
                shortcutKeycap("⌘")
                shortcutKeycap("R")
                Text("starts recording from anywhere")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Press Shift Command R to start recording from anywhere")

        case .welcome:
            EmptyView()
        }
    }

    private func surfaceRow(symbol: String, name: String, detail: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name). \(detail)")
    }

    private func shortcutKeycap(_ label: String) -> some View {
        Text(label)
            .font(.system(.body, weight: .semibold))
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(DesignTokens.Palette.fill(.selected, contrast: contrast))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip", action: skip)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityHint("Dismiss onboarding")

            Spacer()

            pageDots

            Spacer()

            HStack(spacing: DesignTokens.Spacing.sm) {
                if stepIndex > 0 {
                    Button("Back") { advance(by: -1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(isLastStep ? "Get Started" : "Continue") {
                    if isLastStep { finish() } else { advance(by: 1) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(visibleStepCount.indices, id: \.self) { i in
                Circle()
                    .fill(i == stepIndex ? accent : DesignTokens.Palette.fill(.strong, contrast: contrast))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(stepIndex + 1) of \(visibleStepCount.count)")
    }

    // MARK: - Steps model

    private enum StepKind { case welcome, surfaces, microphone, systemAudio, recordShortcut }

    private struct Step: Identifiable {
        let id = UUID()
        let kind: StepKind
        let symbol: String
        let title: String
        let body: String

        static let all: [Step] = [
            Step(kind: .welcome,
                 symbol: "text.quote",
                 title: "Welcome to Scribe",
                 body: "A calm place to record conversations, transcribe them on-device, and turn them into notes and tasks — all privately, all yours."),
            Step(kind: .surfaces,
                 symbol: "square.grid.2x2",
                 title: "Three places to work",
                 body: "Scribe is three surfaces in one. Capture records and transcribes your conversations. Notes is a markdown notebook for writing things down. Tasks keeps your to-dos in view."),
            Step(kind: .microphone,
                 symbol: "mic",
                 title: "Hear yourself think",
                 body: "Scribe needs your microphone to capture what you say. Grant access below — the meter will move when it can hear you."),
            Step(kind: .systemAudio,
                 symbol: "speaker.wave.2",
                 title: "Bring others into the room",
                 body: "For calls and meetings, Scribe can also transcribe the people on the other end by capturing your system audio. Skip this if you only record yourself."),
            Step(kind: .recordShortcut,
                 symbol: "record.circle",
                 title: "Ready when you are",
                 body: "Your first recording downloads a small on-device speech model — about a minute, just once. After that, start instantly from anywhere:")
        ]
    }

    /// The set of steps to actually show. The system-audio step is only
    /// relevant when the user intends to capture meetings.
    private var visibleStepCount: [Step] {
        steps.filter { $0.kind != .systemAudio || captureSystemAudio }
    }

    private var step: Step {
        let list = visibleStepCount
        return list[min(stepIndex, list.count - 1)]
    }

    private var isLastStep: Bool { stepIndex >= visibleStepCount.count - 1 }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Actions

    private func advance(by delta: Int) {
        let next = stepIndex + delta
        guard next >= 0, next < visibleStepCount.count else { return }
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            stepIndex = next
        }
    }

    private func skip() {
        finish()
    }

    private func finish() {
        hasCompletedOnboarding = true
        stopDemo()
        isPresented = false
    }

    private func handleStepChange() {
        if step.kind == .microphone {
            refreshMicStatus()
            startDemoIfNeeded()
        } else {
            stopDemo()
        }
    }

    // MARK: - Microphone

    private func refreshMicStatus() {
        Task {
            let status = await Permissions.checkMicrophonePermission()
            await MainActor.run { micGranted = (status == .granted) }
        }
    }

    private func requestMic() {
        guard !micRequestInFlight else { return }
        micRequestInFlight = true
        Task {
            let granted = await Permissions.requestMicrophonePermission()
            await MainActor.run {
                micGranted = granted
                micRequestInFlight = false
                if !granted {
                    Permissions.openSystemPreferences(for: "Privacy_Microphone")
                }
            }
        }
    }

    // MARK: - Demo level (preview only)

    /// The level the meter renders: the live mic level if a real session is
    /// running, otherwise a gentle scripted demo so the user sees motion.
    private var previewLevel: Float {
        audioManager.isRecording ? audioManager.inputLevel : demoLevel
    }

    private func startDemoIfNeeded() {
        guard !audioManager.isRecording, demoTimer == nil, !reduceMotion else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
            Task { @MainActor in
                // A soft random walk in the low-mid range — clearly alive
                // without pretending to be real captured audio.
                let target = Float.random(in: 0.12...0.55)
                withAnimation(.easeInOut(duration: 0.18)) {
                    demoLevel = target
                }
            }
        }
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoLevel = 0
    }
}
