// Extensions/ScribeRecordingActivity/ScribeRecordingActivityBundle.swift
//
// iOS / iPadOS widget extension holding ONLY the recording Live Activity
// (Lock Screen banner + Dynamic Island). Home / Lock Screen widgets live in
// a separate extension. Lives outside Scribe/ so the macOS `swift test` build
// never sees WidgetKit's `@main` bundle. The attributes and the Stop / Pause
// intents are shared with the app (ScribeiOS/Recording/LiveActivityShared).

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ScribeRecordingActivityBundle: WidgetBundle {
    var body: some Widget {
        ScribeRecordingLiveActivity()
    }
}

struct ScribeRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScribeRecordingActivityAttributes.self) { context in
            ScribeRecordingLockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(Color.white)
                .widgetURL(context.attributes.openURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ScribeRecordingStatusIcon(isPaused: context.state.isPaused)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ScribeRecordingElapsedText(state: context.state)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !context.state.latestLine.isEmpty {
                            Text(context.state.latestLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        ScribeRecordingActivityButtons(isPaused: context.state.isPaused)
                    }
                }
            } compactLeading: {
                ScribeRecordingStatusIcon(isPaused: context.state.isPaused)
            } compactTrailing: {
                ScribeRecordingElapsedText(state: context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                ScribeRecordingStatusIcon(isPaused: context.state.isPaused)
            }
            .widgetURL(context.attributes.openURL)
            .keylineTint(Color.red)
        }
    }
}

// MARK: - Views

struct ScribeRecordingLockScreenView: View {
    let attributes: ScribeRecordingActivityAttributes
    let state: ScribeRecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ScribeRecordingStatusIcon(isPaused: state.isPaused)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.isPaused ? "Paused · Scribe" : "Recording · Scribe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ScribeRecordingElapsedText(state: state)
                    .font(.title2.weight(.semibold))
            }
            if !state.latestLine.isEmpty {
                Text(state.latestLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ScribeRecordingActivityButtons(isPaused: state.isPaused)
        }
    }
}

struct ScribeRecordingStatusIcon: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.circle.fill" : "waveform.circle.fill")
            .foregroundStyle(isPaused ? Color.orange : Color.red)
            .accessibilityLabel(isPaused ? "Paused" : "Recording")
    }
}

/// A running timer while recording, the frozen time while paused.
struct ScribeRecordingElapsedText: View {
    let state: ScribeRecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPaused {
                Text(state.elapsedLabel)
            } else {
                Text(state.timerStart, style: .timer)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

struct ScribeRecordingActivityButtons: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ScribeToggleRecordingPauseActivityIntent()) {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(Color.orange)
            Button(intent: ScribeStopRecordingActivityIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(Color.red)
        }
        .buttonStyle(.borderedProminent)
        .font(.subheadline.weight(.semibold))
    }
}
