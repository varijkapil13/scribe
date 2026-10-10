// Extensions/ScribeiOSWidgets/ScribeiOSNextMeetingWidget.swift
//
// "Next Meeting" on iPhone / iPad: the next calendar event with a live
// countdown and a Record button (ScribeStartRecordingControlIntent opens
// Scribe and starts recording). While Scribe is recording it shows the
// elapsed time instead. Home Screen / StandBy (small, medium) and Lock Screen
// (circular, rectangular, inline).

import AppIntents
import SwiftUI
import WidgetKit

struct ScribeiOSNextMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ScribeiOSWidgetKinds.nextMeeting,
            provider: ScribeSnapshotTimelineProvider()
        ) { entry in
            ScribeiOSNextMeetingWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Meeting")
        .description("Your next meeting with a countdown and a button to start recording in Scribe.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct ScribeiOSNextMeetingWidgetView: View {

    let entry: ScribeWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var meeting: ScribeSharedSnapshot.Meeting? {
        entry.snapshot.nextMeeting(at: entry.date)
    }

    private var recording: ScribeSharedSnapshot.RecordingState { entry.snapshot.recording }

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
            .widgetURL(ScribeAppGroup.todayURL)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            home
        }
    }

    // MARK: - Home Screen / StandBy

    private var home: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Next Meeting", systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .widgetAccentable()

            if let meeting {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(family == .systemSmall ? 2 : 1)
                countdown(for: meeting)
            } else {
                Text("No more meetings in the next 24 hours")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            recordControl
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func countdown(for meeting: ScribeSharedSnapshot.Meeting) -> some View {
        if meeting.isInProgress(at: entry.date) {
            HStack(spacing: 4) {
                Text("Now · ends")
                Text(meeting.end, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.red)
        } else {
            HStack(spacing: 4) {
                Text("In")
                Text(meeting.start, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(meeting.start, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recordControl: some View {
        if recording.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                if let startedAt = recording.startedAt {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                } else {
                    Text("Recording")
                }
            }
            .font(.callout)
        } else {
            Button(intent: ScribeStartRecordingControlIntent()) {
                Label("Record", systemImage: "record.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if recording.isRecording {
                Image(systemName: "record.circle.fill")
                    .font(.title2)
                    .widgetAccentable()
            } else if let meeting {
                VStack(spacing: 0) {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .widgetAccentable()
                    Text(meeting.start, style: .time)
                        .font(.system(size: 11, weight: .semibold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .padding(4)
            } else {
                Image(systemName: "calendar")
                    .font(.title3)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if recording.isRecording {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.headline)
                    .widgetAccentable()
                if let startedAt = recording.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.caption)
                        .monospacedDigit()
                }
            } else if let meeting {
                Label("Next meeting", systemImage: "calendar")
                    .font(.caption)
                    .widgetAccentable()
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                if meeting.isInProgress(at: entry.date) {
                    Text("Now")
                        .font(.caption)
                } else {
                    Text(meeting.start, style: .time)
                        .font(.caption)
                }
            } else {
                Label("No more meetings", systemImage: "calendar")
                    .font(.headline)
                    .widgetAccentable()
                Text("Nothing in the next 24 hours")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var inline: some View {
        if recording.isRecording {
            Label("Scribe is recording", systemImage: "record.circle")
        } else if let meeting {
            if meeting.isInProgress(at: entry.date) {
                Label("Now: \(meeting.title)", systemImage: "calendar")
            } else {
                Label {
                    Text("\(meeting.start, style: .time) \(meeting.title)")
                } icon: {
                    Image(systemName: "calendar")
                }
            }
        } else {
            Label("No more meetings", systemImage: "calendar")
        }
    }
}
