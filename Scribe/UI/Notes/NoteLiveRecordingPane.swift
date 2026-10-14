// Scribe/UI/Notes/NoteLiveRecordingPane.swift
import SwiftUI

/// Compact live-transcript readout shown inside a Note's detail view while a
/// recording bound to that note is in progress. Mirrors LiveSessionView's
/// streaming pattern but trimmed to fit above the freeform editor.
struct NoteLiveRecordingPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NoteLiveRecordingPaneContent(appState: appState, status: appState.recordingStatus)
    }
}

private struct NoteLiveRecordingPaneContent: View {
    let appState: AppState
    @ObservedObject var status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header
            transcriptScroll
        }
        .padding(.horizontal, 20)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceSunken)
    }

    /// Shared live-feed identity so the in-note pane reads as the same session
    /// as the full `LiveSessionView` and the floating controller: same state
    /// label, tint, glyph, and elapsed-time formatting, driven by the one
    /// `AudioSessionManager` clock.
    private var header: some View {
        RecordingElapsed(clock: appState.recordingClock) { duration in
            LiveFeedHeader(
                status: .resolve(isTranscribing: status.isRecording,
                                 isPaused: status.isPaused),
                duration: duration
            )
        }
    }

    private var transcriptScroll: some View {
        LiveTranscriptFeedSource(
            transcript: appState.liveTranscript,
            speechEngine: appState.speechEngine,
            density: .compact,
            isTranscribing: status.isRecording,
            isPaused: status.isPaused,
            // Show the listening/empty state so the pane matches the full live
            // view while we wait for the first words; the shared header above
            // already carries the session identity.
            showsListeningState: true,
            maxHeight: 160
        )
    }
}
