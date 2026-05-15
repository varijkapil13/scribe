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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(appState.overlaySegments) { segment in
                        liveLine(speaker: segment.speaker, text: segment.text)
                            .id(segment.id)
                    }
                    if !appState.speechEngine.partialResult.isEmpty {
                        liveLine(speaker: "…", text: appState.speechEngine.partialResult)
                            .foregroundStyle(.secondary)
                            .id("partial")
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            .frame(maxHeight: 160)
            .onChange(of: appState.overlaySegments.count) {
                if let last = appState.overlaySegments.last {
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

    private func liveLine(speaker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(speaker)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
