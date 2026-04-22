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
                Text(statusLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Text(formattedDuration)
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .accessibilityLabel("Duration: \(formattedDuration)")
            }

            Spacer()

            Button {
                alwaysOnTop.toggle()
                updatePanelFloatingState(alwaysOnTop)
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin.slash")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(alwaysOnTop ? Color.accentColor : Color.secondary)
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
