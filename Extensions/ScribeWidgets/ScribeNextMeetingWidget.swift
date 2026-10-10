// Extensions/ScribeWidgets/ScribeNextMeetingWidget.swift
//
// "Next Meeting": the next calendar event with a live countdown and a Record
// button (scribe://record/start). While Scribe is recording it shows the
// elapsed time instead.

import SwiftUI
import WidgetKit

struct ScribeNextMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ScribeAppGroup.nextMeetingWidgetKind,
            provider: ScribeSnapshotTimelineProvider()
        ) { entry in
            ScribeNextMeetingWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Meeting")
        .description("Your next meeting with a countdown and a button to start recording in Scribe.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ScribeNextMeetingWidgetView: View {

    let entry: ScribeWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var meeting: ScribeSharedSnapshot.Meeting? {
        entry.snapshot.nextMeeting(at: entry.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Next Meeting", systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.snapshot.recording.isRecording ? ScribeAppGroup.todayURL : ScribeAppGroup.recordStartURL)
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
        if entry.snapshot.recording.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                if let startedAt = entry.snapshot.recording.startedAt {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                } else {
                    Text("Recording")
                }
            }
            .font(.callout)
        } else {
            // Small widgets are one tap target (widgetURL above); larger
            // sizes get a real link button.
            if family == .systemSmall {
                recordLabel
            } else {
                Link(destination: ScribeAppGroup.recordStartURL) {
                    recordLabel
                }
            }
        }
    }

    private var recordLabel: some View {
        Label("Record", systemImage: "record.circle")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.red)
    }
}
