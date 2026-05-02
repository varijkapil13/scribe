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
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID: String = ""
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live recording")
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

            audioSourceRow
        }
    }

    private var eyebrow: String {
        if appState.audioManager.isPaused { return "PAUSED" }
        if appState.isTranscribing { return "RECORDING" }
        return "READY"
    }

    private var eyebrowTint: Color {
        if appState.audioManager.isPaused { return DesignTokens.Palette.paused }
        if appState.isTranscribing { return DesignTokens.Palette.recording }
        return .secondary
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                if appState.audioManager.isPaused {
                    Task { await appDelegate.resumeRecording() }
                } else {
                    appDelegate.pauseRecording()
                }
            } label: {
                Label(appState.audioManager.isPaused ? "Resume" : "Pause",
                      systemImage: appState.audioManager.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!appState.isTranscribing)

            Button {
                Task { await appDelegate.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(DesignTokens.Palette.recording)
            .disabled(!appState.isTranscribing)
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
            HStack(spacing: 2) {
                Text(languageDisplay)
                    .font(DesignTokens.Typography.eyebrow)
                    .tracking(0.8)
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

    // MARK: - Transcript feed

    private var transcriptFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(segments) { segment in
                        liveRow(for: segment)
                            .id(segment.id)
                    }

                    if !appState.speechEngine.partialResult.isEmpty {
                        partialRow(text: appState.speechEngine.partialResult)
                            .id("partial")
                    }

                    if segments.isEmpty && appState.speechEngine.partialResult.isEmpty {
                        listeningState
                    }
                }
                .padding(DesignTokens.Spacing.xl)
            }
            .onChange(of: segments.count) {
                if let last = segments.last {
                    withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: appState.speechEngine.partialResult) {
                if !appState.speechEngine.partialResult.isEmpty {
                    withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) {
                        proxy.scrollTo("partial", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var segments: [TranscriptionSegment] {
        appState.overlaySegments
    }

    private func liveRow(for segment: TranscriptionSegment) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.speakerTint(for: segment.speaker))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    SpeakerChip(speaker: segment.speaker)
                    Text(timestampString(for: segment))
                        .font(DesignTokens.Typography.timestamp)
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.speaker) at \(timestampString(for: segment)): \(segment.text)")
    }

    private func partialRow(text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3)

            Text(text)
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    private var listeningState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            if appState.speechEngine.isDownloadingModel {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: appState.isTranscribing ? "waveform" : "mic.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.variableColor.iterative, isActive: appState.isTranscribing)
            }

            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(listeningHeadline)
                    .font(DesignTokens.Typography.section)
                    .foregroundStyle(.primary)
                Text(listeningSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Spacing.xxl)
    }

    private var listeningHeadline: String {
        if appState.speechEngine.isDownloadingModel { return "Downloading speech model…" }
        if appState.isTranscribing { return "Listening…" }
        return "Ready to record"
    }

    private var listeningSubtitle: String {
        if appState.speechEngine.isDownloadingModel {
            return "First-time setup for this language. This usually takes under a minute."
        }
        if appState.isTranscribing {
            return "Transcribed segments will appear here as you speak."
        }
        return "Start a session to see the live transcript."
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let total = Int(appState.audioManager.recordingDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func timestampString(for segment: TranscriptionSegment) -> String {
        let total = segment.sessionOffsetMs / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var currentMicDisplayName: String {
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
