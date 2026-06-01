// Scribe/UI/Notes/NoteLiveRecordingPane.swift
import SwiftUI

/// Compact live-transcript readout shown inside a Note's detail view while a
/// recording bound to that note is in progress. Mirrors LiveSessionView's
/// streaming pattern but trimmed to fit above the freeform editor.
struct NoteLiveRecordingPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header
            transcriptScroll
        }
        .padding(.horizontal, 20)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceSunken)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(DesignTokens.Palette.recording)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Recording in progress")
            Text("Recording")
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var transcriptScroll: some View {
        LiveTranscriptFeed(
            segments: appState.overlaySegments,
            partial: appState.speechEngine.partialResult,
            density: .compact,
            isTranscribing: appState.isTranscribing,
            isDownloadingModel: appState.speechEngine.isDownloadingModel,
            // The pane already shows its own "Recording" header, so the
            // listening/empty card would be redundant here.
            showsListeningState: false,
            maxHeight: 160
        )
    }
}
