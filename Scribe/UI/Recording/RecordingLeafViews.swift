import SwiftUI

/// Renders `content` from the recording clock, so only this subtree
/// re-renders when the elapsed second changes.
struct RecordingElapsed<Content: View>: View {
    @ObservedObject var clock: RecordingClock
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        content(clock.elapsed)
    }
}

/// Renders `content` from the live-transcript rows, so the containing view
/// doesn't re-render for every recognised segment.
struct LiveTranscriptReader<Content: View>: View {
    @ObservedObject var transcript: LiveTranscript
    @ViewBuilder let content: ([TranscriptionSegment]) -> Content

    var body: some View {
        content(transcript.segments)
    }
}

/// `LevelMeterView` bound to the audio manager. The levels publish at ~13 Hz,
/// so this is the only view that should observe `AudioSessionManager` for them.
struct LiveLevelMeter: View {
    enum Source { case input, system }

    @ObservedObject var audioManager: AudioSessionManager
    let source: Source
    var tint: Color?
    var barCount: Int = 12
    var sourceLabel: String?

    var body: some View {
        LevelMeterView(
            level: source == .input ? audioManager.inputLevel : audioManager.systemLevel,
            tint: tint,
            barCount: barCount,
            sourceLabel: sourceLabel
        )
    }
}

/// The live transcript feed, observing the rows and the speech engine's
/// partial result itself.
struct LiveTranscriptFeedSource: View {
    @ObservedObject var transcript: LiveTranscript
    @ObservedObject var speechEngine: SpeechRecognizerEngine
    var density: LiveTranscriptFeed.Density = .comfortable
    let isTranscribing: Bool
    let isPaused: Bool
    var showsListeningState: Bool = true
    var maxHeight: CGFloat?

    var body: some View {
        LiveTranscriptFeed(
            segments: transcript.segments,
            partial: speechEngine.partialResult,
            density: density,
            isTranscribing: isTranscribing,
            isPaused: isPaused,
            isDownloadingModel: speechEngine.isDownloadingModel,
            showsListeningState: showsListeningState,
            maxHeight: maxHeight
        )
    }
}

/// Pulsing halo behind a recording dot. Insert it only while the pulse should
/// run: removing it is what stops the repeating animation.
struct RecordingPulseHalo: View {
    let tint: Color
    @State private var pulse: CGFloat = 0

    var body: some View {
        Circle()
            .fill(tint.opacity(0.35))
            .frame(width: 14, height: 14)
            .scaleEffect(0.9 + pulse * 0.5)
            .opacity(0.6 - pulse * 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = 1
                }
            }
    }
}
