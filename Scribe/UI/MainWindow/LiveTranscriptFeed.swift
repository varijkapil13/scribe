import SwiftUI

/// The single live-transcript stream view, shared by the full-window
/// `LiveSessionView` (`.comfortable`) and the in-note `NoteLiveRecordingPane`
/// (`.compact`). It owns the `ScrollViewReader`, auto-scroll-to-newest
/// (reduce-motion gated), speaker tinting + a non-color speaker cue, partial-line
/// styling, and the listening/empty state.
///
/// VoiceOver: rather than announcing every segment (a firehose, since segments
/// stream in continuously), it posts a rate-limited live-region announcement of
/// only the latest *finalized* line, and offers an explicit "Read latest line"
/// affordance for on-demand catch-up.
struct LiveTranscriptFeed: View {

    enum Density {
        case compact     // in-note pane: tight rows, trailing speaker label
        case comfortable // full live view: roomy rows, speaker chip + timestamp
    }

    let segments: [TranscriptionSegment]
    let partial: String
    var density: Density = .comfortable

    /// Drives the empty/listening state copy. When `nil` the feed simply shows
    /// nothing while empty (the compact pane has its own header).
    var isTranscribing: Bool = false
    /// When the session is paused, the empty-state copy says so instead of
    /// claiming we're listening — nothing new will arrive until resume.
    var isPaused: Bool = false
    var isDownloadingModel: Bool = false
    /// When true, the comfortable variant shows the full listening/empty card.
    var showsListeningState: Bool = true
    /// Maximum height for the scroll area (compact pane uses a fixed cap).
    var maxHeight: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Throttle state for the VoiceOver live region.
    @State private var lastAnnouncedSegmentId: UUID?
    @State private var lastAnnouncedAt: Date = .distantPast

    /// Minimum gap between automatic live-region announcements.
    private let announceInterval: TimeInterval = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(segments) { segment in
                        row(for: segment)
                            .id(segment.id)
                            .transition(entranceTransition)
                    }

                    if !partial.isEmpty {
                        partialRow(text: partial)
                            .id("partial")
                    }

                    if isEmpty && showsListeningState {
                        listeningState
                    }
                }
                .padding(contentPadding)
            }
            .frame(maxHeight: maxHeight)
            .scribeAnimation(.snappy, value: segments.count)
            .onChange(of: segments.count) {
                scrollToNewest(proxy)
                maybeAnnounceLatest()
            }
            .onChange(of: partial) {
                if !partial.isEmpty { scrollToNewest(proxy, partial: true) }
            }
            .overlay(alignment: .topTrailing) {
                if voiceOverEnabled && !segments.isEmpty {
                    readLatestButton
                        .padding(DesignTokens.Spacing.sm)
                }
            }
        }
    }

    private var isEmpty: Bool { segments.isEmpty && partial.isEmpty }

    // MARK: - Rows

    @ViewBuilder
    private func row(for segment: TranscriptionSegment) -> some View {
        switch density {
        case .comfortable: comfortableRow(for: segment)
        case .compact:     compactRow(for: segment)
        }
    }

    private func comfortableRow(for segment: TranscriptionSegment) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.speakerTint(for: segment.speaker))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    speakerCue(for: segment.speaker)
                    Text(timestampString(forMs: segment.sessionOffsetMs))
                        .font(DesignTokens.Typography.timestamp)
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerDisplayName(segment.speaker)) at \(timestampString(forMs: segment.sessionOffsetMs)): \(segment.text)")
    }

    private func compactRow(for segment: TranscriptionSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: 3) {
                // Non-color speaker cue first so it survives Differentiate
                // Without Color; the colored dot is supplementary.
                Image(systemName: Color.speakerSymbol(for: segment.speaker))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.speakerTint(for: segment.speaker))
                Text(speakerDisplayName(segment.speaker))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70, alignment: .trailing)

            Text(segment.text)
                .font(DesignTokens.Typography.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerDisplayName(segment.speaker)): \(segment.text)")
    }

    private func partialRow(text: String) -> some View {
        Group {
            switch density {
            case .comfortable:
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 3)
                    Text(text)
                        .font(DesignTokens.Typography.body)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .compact:
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text("…")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    Text(text)
                        .font(DesignTokens.Typography.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .transition(.opacity)
        .accessibilityLabel("In progress: \(text)")
    }

    /// Non-color speaker cue for the comfortable row: a glyph-led chip when
    /// Differentiate Without Color is on, the colored `SpeakerChip` otherwise.
    @ViewBuilder
    private func speakerCue(for speaker: String) -> some View {
        if differentiateWithoutColor {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: Color.speakerSymbol(for: speaker))
                    .font(.system(size: 10, weight: .semibold))
                Text(speakerDisplayName(speaker))
                    .font(.system(.caption2, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            .foregroundStyle(.secondary)
        } else {
            SpeakerChip(speaker: speaker)
        }
    }

    // MARK: - Listening / empty state

    private var listeningState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            if isDownloadingModel {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: listeningIcon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.variableColor.iterative, isActive: isTranscribing && !isPaused && !reduceMotion)
            }

            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(listeningHeadline)
                    .font(DesignTokens.Typography.section)
                    .foregroundStyle(.primary)
                Text(listeningSubtitle)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Spacing.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(listeningHeadline). \(listeningSubtitle)")
    }

    private var listeningIcon: String {
        if isPaused { return "pause.fill" }
        return isTranscribing ? "waveform" : "mic.slash"
    }

    private var listeningHeadline: String {
        if isDownloadingModel { return "Downloading speech model…" }
        if isPaused { return "Paused" }
        if isTranscribing { return "Listening…" }
        return "Ready to record"
    }

    private var listeningSubtitle: String {
        if isDownloadingModel {
            return "First-time setup for this language. This usually takes under a minute."
        }
        if isPaused {
            return "Recording is paused. Resume to continue transcribing."
        }
        if isTranscribing {
            return "Transcribed segments will appear here as you speak."
        }
        return "Start a session to see the live transcript."
    }

    // MARK: - Read-latest affordance

    private var readLatestButton: some View {
        Button {
            announceLatest(force: true)
        } label: {
            Label("Read latest line", systemImage: "speaker.wave.2.bubble.left")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .padding(DesignTokens.Spacing.xs)
        }
        .buttonStyle(.plain)
        .background(Circle().scribeGlass(.hud, in: Circle()))
        .accessibilityLabel("Read latest line")
        .accessibilityHint("Announces the most recent finalized transcript line")
    }

    // MARK: - Auto-scroll

    private func scrollToNewest(_ proxy: ScrollViewProxy, partial: Bool = false) {
        let target: AnyHashable? = partial ? "partial" : segments.last?.id
        guard let target else { return }
        if reduceMotion {
            proxy.scrollTo(target, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    // MARK: - VoiceOver live region (rate-limited)

    /// Auto-announce the latest finalized line, but only when VoiceOver is on
    /// and at most once per `announceInterval` so the user isn't flooded.
    private func maybeAnnounceLatest() {
        guard voiceOverEnabled else { return }
        guard let latest = segments.last, latest.id != lastAnnouncedSegmentId else { return }
        guard Date().timeIntervalSince(lastAnnouncedAt) >= announceInterval else { return }
        announceLatest(force: false)
    }

    private func announceLatest(force: Bool) {
        guard let latest = segments.last else { return }
        if !force {
            lastAnnouncedAt = Date()
            lastAnnouncedSegmentId = latest.id
        } else {
            lastAnnouncedSegmentId = latest.id
        }
        let message = "\(speakerDisplayName(latest.speaker)): \(latest.text)"
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Layout tokens

    private var rowSpacing: CGFloat {
        density == .comfortable ? DesignTokens.Spacing.md : DesignTokens.Spacing.xs
    }

    private var contentPadding: CGFloat {
        density == .comfortable ? DesignTokens.Spacing.xl : DesignTokens.Spacing.xs
    }

    private var entranceTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    // MARK: - Helpers

    private func speakerDisplayName(_ speaker: String) -> String {
        switch speaker.lowercased() {
        case "you":    return "You"
        case "remote": return "Remote"
        default:       return speaker.capitalized
        }
    }

    private func timestampString(forMs ms: Int) -> String {
        let total = ms / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
