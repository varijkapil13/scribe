import SwiftUI

// MARK: - DisplaySegment

/// A view-level model representing a single transcript segment for display in the overlay.
struct DisplaySegment: Identifiable, Equatable {

    let id: UUID
    let timestamp: String
    let speaker: String
    let text: String

    init(id: UUID = UUID(), timestamp: String, speaker: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }

    /// Convenience initialiser for the storage `Segment` type.
    init(from segment: Segment) {
        self.id = UUID()
        self.timestamp = segment.formattedTimestamp
        self.speaker = segment.speaker
        self.text = segment.text
    }
}

// MARK: - OverlayView

/// Floating transcript overlay. Displays a compact "recording hero" header
/// (status pill + large duration readout) and a scrolling live transcript
/// with italic partial text at the bottom so the user can see words forming
/// in real time.
struct OverlayView: View {

    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject var appState: AppState
    @ObservedObject var speechEngine: SpeechRecognizerEngine

    /// Transport-control callbacks wired from ``AppDelegate`` so the menu-bar
    /// icon, timer, and overlay stay in sync regardless of where the user
    /// toggles state. Optional for preview/testing.
    var onPauseResume: (() -> Void)?
    var onStop: (() -> Void)?

    @AppStorage("captureSystemAudio") private var captureSystemAudio: Bool = true
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID: String = ""
    @State private var alwaysOnTop: Bool = true

    private var segments: [DisplaySegment] {
        appState.overlaySegments.map { segment in
            DisplaySegment(
                id: segment.id,
                timestamp: segment.sessionOffsetMs.formattedTimestamp,
                speaker: segment.speaker,
                text: segment.text
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            heroHeader
                .padding(DesignTokens.Spacing.md)
                .background(.ultraThinMaterial)

            Divider().opacity(0.6)

            transcriptScrollArea
        }
        .frame(minWidth: 320, minHeight: 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Transcript Overlay")
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            statusIndicator

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(statusLabel)
                        .font(.system(.caption2, weight: .semibold))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    languageMenu
                }

                Text(formattedDuration)
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .accessibilityLabel("Duration: \(formattedDuration)")
            }

            Spacer()

            transportControls
        }
    }

    // MARK: - Transport Controls

    @ViewBuilder
    private var transportControls: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if audioManager.isRecording {
                Button {
                    onPauseResume?()
                } label: {
                    Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(audioManager.isPaused ? "Resume" : "Pause")
                .accessibilityLabel(audioManager.isPaused ? "Resume recording" : "Pause recording")

                Button {
                    onStop?()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.recording)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
            }

            micMenu

            Toggle(isOn: $captureSystemAudio) {
                Image(systemName: captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(captureSystemAudio ? Color.accentColor : Color.secondary)
            .help(captureSystemAudio
                  ? "System audio capture on — remote participants are transcribed"
                  : "System audio capture off — only microphone is transcribed")
            .accessibilityLabel(captureSystemAudio ? "System audio on" : "System audio off")

            Button {
                alwaysOnTop.toggle()
                updatePanelFloatingState(alwaysOnTop)
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(alwaysOnTop ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(alwaysOnTop ? "Pinned above all windows" : "Floating disabled")
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if audioManager.isRecording && !audioManager.isPaused {
            ZStack {
                Circle()
                    .fill(DesignTokens.Palette.recording.opacity(0.25))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulseScale)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: audioManager.isRecording)
                Circle()
                    .fill(DesignTokens.Palette.recording)
                    .frame(width: 10, height: 10)
            }
            .accessibilityLabel("Recording")
        } else if audioManager.isPaused {
            Circle()
                .fill(DesignTokens.Palette.paused)
                .frame(width: 10, height: 10)
                .accessibilityLabel("Paused")
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
                .accessibilityLabel("Idle")
        }
    }

    private var pulseScale: CGFloat {
        audioManager.isRecording && !audioManager.isPaused ? 1.35 : 1.0
    }

    private var statusLabel: String {
        if audioManager.isPaused { return "Paused" }
        if audioManager.isRecording { return "Recording" }
        return "Idle"
    }

    /// Currently-selected language pref, read once per view refresh from
    /// UserDefaults. Stays in sync with Settings because both read/write the
    /// same key, and AppState observes changes to re-tune SFSpeech live.
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"

    /// Dropdown of available microphones. Writing `selectedMicrophoneID`
    /// triggers `AppState`'s observer which hot-swaps the mic device via
    /// `AudioSessionManager.setInputDevice` — mid-session switching works.
    private var micMenu: some View {
        Menu {
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
            ForEach(audioManager.availableMicrophones(), id: \.id) { mic in
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
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose input device: \(currentMicDisplayName)")
        .accessibilityLabel("Microphone: \(currentMicDisplayName)")
    }

    private var currentMicDisplayName: String {
        if selectedMicrophoneID.isEmpty { return "System Default" }
        return audioManager.availableMicrophones()
            .first(where: { String($0.id) == selectedMicrophoneID })?.name
            ?? "Unknown device"
    }

    /// Inline language dropdown in the overlay header. Writing to
    /// `selectedLanguage` is picked up by AppState's observer and the speech
    /// engine is re-tuned mid-session, so switching takes effect immediately.
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
            HStack(spacing: 2) {
                Text(languageDisplay)
                    .font(.system(.caption2, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
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

    /// Short code rendered in the header pill — the engine's currentLanguage
    /// overrides the stored pref once a session is running so the user sees
    /// the *actual* recogniser locale (e.g. "DE" from "de-DE").
    private var languageDisplay: String {
        if let lang = speechEngine.currentLanguage, !lang.isEmpty {
            return LanguageOptions.shortLabel(for: lang)
        }
        return LanguageOptions.shortLabel(for: selectedLanguage)
    }

    // MARK: - Transcript

    private var transcriptScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(segments) { segment in
                        overlayRow(for: segment)
                            .id(segment.id)
                    }

                    if !speechEngine.partialResult.isEmpty {
                        partialRow(text: speechEngine.partialResult)
                            .id("partial")
                    }

                    if segments.isEmpty && speechEngine.partialResult.isEmpty {
                        overlayEmptyState
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
            .onChange(of: segments.count) {
                if let last = segments.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: speechEngine.partialResult) {
                if !speechEngine.partialResult.isEmpty {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("partial", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func overlayRow(for segment: DisplaySegment) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.speakerTint(for: segment.speaker))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    SpeakerChip(speaker: segment.speaker)
                    Text(segment.timestamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.speaker) at \(segment.timestamp): \(segment.text)")
    }

    private func partialRow(text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 2.5)
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    private var overlayEmptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: audioManager.isRecording ? "waveform" : "mic.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, isActive: audioManager.isRecording)
            Text(audioManager.isRecording ? "Listening…" : "Press Start to begin recording")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let total = Int(audioManager.recordingDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func updatePanelFloatingState(_ shouldFloat: Bool) {
        guard let panel = NSApp.windows.compactMap({ $0 as? OverlayPanel }).first else { return }
        panel.level = shouldFloat ? .floating : .normal
        panel.isFloatingPanel = shouldFloat
    }
}
