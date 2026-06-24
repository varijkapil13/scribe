import SwiftUI

/// Primary detail view shown while a session is active. Replaces the old
/// floating `OverlayPanel` — same live transcript + transport + audio-source
/// controls, but inline in the main window so everything lives in one place.
///
/// Structure (top-to-bottom):
/// 1. **Hero** — eyebrow + big monospaced timer + status, flanked by transport
///    and audio-source controls.
/// 2. **Transcript feed** — streaming segments (`appState.overlaySegments`)
///    plus the in-progress partial, auto-scrolling to the newest line.
///
/// Visual language matches `TranscriptDetailView`: eyebrow → big display,
/// softly-bordered card surfaces, tabular digits, no chrome flashes.
struct LiveSessionView: View {

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appDelegate: AppDelegate

    @AppStorage("captureSystemAudio") private var captureSystemAudio: Bool = true
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID: String = "auto"
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"

    /// Drives `.sensoryFeedback` so start/stop/pause confirm with a haptic.
    @State private var feedbackTrigger: RecordingFeedback = .none

    /// True while an async resume is in flight, so the transport button is
    /// disabled and rapid clicks can't queue multiple `resumeRecording()` calls.
    @State private var isResuming = false

    private enum RecordingFeedback: Equatable {
        case none, started, stopped, paused, resumed
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.top, DesignTokens.Spacing.xl)
                .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()

            transcriptFeed
        }
        .background(DesignTokens.Palette.surface)
        // Transport shortcuts (Space = pause/resume, ⌘. = stop) live on the
        // transport buttons via `.keyboardShortcut`, which scopes them to this
        // view's responder subtree — so they never fire while the user is
        // typing in a note editor elsewhere, and VoiceOver announces them. We
        // deliberately avoid a container-level `.onKeyPress` here to prevent
        // double-dispatch with those button shortcuts.
        // Recording feedback: a single trigger value the system maps to a haptic.
        .sensoryFeedback(trigger: feedbackTrigger) { _, new in
            switch new {
            case .started:  return .start
            case .stopped:  return .stop
            case .paused:   return .impact(weight: .light)
            case .resumed:  return .impact(weight: .light)
            case .none:     return nil
            }
        }
        .onChange(of: appState.isTranscribing) { _, now in
            feedbackTrigger = now ? .started : .stopped
        }
        .onChange(of: appState.audioManager.isPaused) { _, paused in
            feedbackTrigger = paused ? .paused : .resumed
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live recording")
    }

    // MARK: - Transport actions

    private func togglePause() {
        if appState.audioManager.isPaused {
            guard !isResuming else { return }
            isResuming = true
            Task {
                await appDelegate.resumeRecording()
                isResuming = false
            }
        } else {
            appDelegate.pauseRecording()
        }
    }

    private func stop() {
        Task { await appDelegate.stopRecording() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text(eyebrow)
                    .eyebrowStyle(tint: eyebrowTint)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                languageMenu
            }

            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.lg) {
                Text(formattedDuration)
                    .font(.system(size: 52, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Elapsed time \(formattedDuration)")

                Spacer(minLength: DesignTokens.Spacing.md)

                transportControls
            }

            levelMeters

            audioSourceRow
        }
    }

    /// Dual input-level meters (you + remote) so the user can *see* that audio
    /// is being heard. Hidden when idle; the remote meter only appears when
    /// system audio is being captured.
    @ViewBuilder
    private var levelMeters: some View {
        if appState.isTranscribing && !appState.audioManager.isPaused {
            HStack(spacing: DesignTokens.Spacing.lg) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.speakerYou)
                        .accessibilityHidden(true)
                    LevelMeterView(level: appState.audioManager.inputLevel,
                                   tint: DesignTokens.Palette.speakerYou,
                                   sourceLabel: "Your microphone")
                }

                if captureSystemAudio {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.speakerRemote)
                            .accessibilityHidden(true)
                        LevelMeterView(level: appState.audioManager.systemLevel,
                                       tint: DesignTokens.Palette.speakerRemote,
                                       sourceLabel: "Remote audio")
                    }
                }
                Spacer()
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        }
    }

    /// Shared live-session state, so the hero's eyebrow + tint classify the
    /// session identically to the in-note pane and the floating controller.
    private var status: LiveFeedStatus {
        .resolve(isTranscribing: appState.isTranscribing,
                 isPaused: appState.audioManager.isPaused)
    }

    private var eyebrow: String { status.eyebrow }

    private var eyebrowTint: Color { status.tint }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                togglePause()
            } label: {
                Label(appState.audioManager.isPaused ? "Resume" : "Pause",
                      systemImage: appState.audioManager.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!appState.isTranscribing || isResuming)
            .accessibilityLabel(appState.audioManager.isPaused ? "Resume recording" : "Pause recording")
            .accessibilityHint("Space")

            Button {
                stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(DesignTokens.Palette.recording)
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!appState.isTranscribing)
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Command period")
        }
    }

    // MARK: - Audio source row

    private var audioSourceRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            micMenu
            systemAudioToggle
            Spacer()
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }

    private var micMenu: some View {
        Menu {
            Button {
                selectedMicrophoneID = "auto"
            } label: {
                if selectedMicrophoneID == "auto" {
                    Label("Automatic (mic in use)", systemImage: "checkmark")
                } else {
                    Text("Automatic (mic in use)")
                }
            }
            Button {
                selectedMicrophoneID = ""
            } label: {
                if selectedMicrophoneID.isEmpty {
                    Label("System Default", systemImage: "checkmark")
                } else {
                    Text("System Default")
                }
            }
            Divider()
            ForEach(appState.audioManager.availableMicrophones(), id: \.id) { mic in
                let tag = String(mic.id)
                Button {
                    selectedMicrophoneID = tag
                } label: {
                    if selectedMicrophoneID == tag {
                        Label(mic.name, systemImage: "checkmark")
                    } else {
                        Text(mic.name)
                    }
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(currentMicDisplayName)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(DesignTokens.Palette.surfaceElevated)
            )
            .overlay(
                Capsule().strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose input device")
        .accessibilityLabel("Microphone: \(currentMicDisplayName)")
    }

    private var systemAudioToggle: some View {
        Button {
            captureSystemAudio.toggle()
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(captureSystemAudio ? "System audio on" : "System audio off")
                    .font(.caption)
            }
            .foregroundStyle(captureSystemAudio ? Color.accentColor : .secondary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(captureSystemAudio
                               ? Color.accentColor.opacity(0.10)
                               : DesignTokens.Palette.surfaceElevated)
            )
            .overlay(
                Capsule().strokeBorder(
                    captureSystemAudio
                        ? Color.accentColor.opacity(0.25)
                        : DesignTokens.Palette.cardBorder,
                    lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(captureSystemAudio
              ? "Remote participants are being transcribed"
              : "Only your microphone is being transcribed")
        .accessibilityLabel(captureSystemAudio ? "System audio on" : "System audio off")
    }

    private var languageMenu: some View {
        Menu {
            ForEach(LanguageOptions.supported, id: \.code) { option in
                Button {
                    selectedLanguage = option.code
                } label: {
                    if option.code == selectedLanguage {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(languageDisplay)
                    .eyebrowStyle()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Transcription language: \(LanguageOptions.displayName(for: selectedLanguage))")
    }

    // MARK: - Transcript feed

    private var transcriptFeed: some View {
        LiveTranscriptFeed(
            segments: appState.overlaySegments,
            partial: appState.speechEngine.partialResult,
            density: .comfortable,
            isTranscribing: appState.isTranscribing,
            isPaused: appState.audioManager.isPaused,
            isDownloadingModel: appState.speechEngine.isDownloadingModel,
            showsListeningState: true
        )
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        LiveFeedStatus.formattedElapsed(appState.audioManager.recordingDuration)
    }

    private var currentMicDisplayName: String {
        if selectedMicrophoneID == "auto" { return "Automatic" }
        if selectedMicrophoneID.isEmpty { return "System Default" }
        return appState.audioManager.availableMicrophones()
            .first(where: { String($0.id) == selectedMicrophoneID })?.name
            ?? "Unknown device"
    }

    private var languageDisplay: String {
        if let lang = appState.speechEngine.currentLanguage, !lang.isEmpty {
            return LanguageOptions.shortLabel(for: lang)
        }
        return LanguageOptions.shortLabel(for: selectedLanguage)
    }
}
