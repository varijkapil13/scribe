// Extensions/ScribeWidgets/ScribeTodayWidget.swift
//
// "Today": the day's top tasks with tappable completion checkboxes
// (`ToggleScribeWidgetTaskIntent` queues the change for the app). Task titles
// deep-link to the task (scribe://task/<id>); the large size also shows the
// next meeting.

import AppIntents
import SwiftUI
import WidgetKit

struct ScribeTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ScribeAppGroup.todayWidgetKind,
            provider: ScribeSnapshotTimelineProvider()
        ) { entry in
            ScribeTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's tasks from Scribe. Check them off right from the widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ScribeTodayWidgetView: View {

    let entry: ScribeWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var rowLimit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 4
        default: return ScribeSharedSnapshot.maxTasks
        }
    }

    private var tasks: [ScribeSharedSnapshot.TaskItem] {
        Array(entry.snapshot.tasks.prefix(rowLimit))
    }

    private var openCount: Int {
        entry.snapshot.tasks.filter { !$0.isCompleted }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if tasks.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing due today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(tasks) { task in
                    ScribeWidgetTaskRow(task: task, now: entry.date)
                }
                Spacer(minLength: 0)
            }
            if family == .systemLarge, let meeting = entry.snapshot.nextMeeting(at: entry.date) {
                Divider()
                ScribeWidgetMeetingLine(meeting: meeting, now: entry.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
        .widgetURL(ScribeAppGroup.todayURL)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Today", systemImage: "sun.max")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 4)
            if openCount > 0 {
                Text("\(openCount)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ScribeWidgetTaskRow: View {

    let task: ScribeSharedSnapshot.TaskItem
    let now: Date

    private var isOverdue: Bool {
        guard let due = task.due, !task.isCompleted else { return false }
        return due < Calendar.current.startOfDay(for: now)
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(
                isOn: task.isCompleted,
                intent: ToggleScribeWidgetTaskIntent(taskId: task.id, isCompleted: !task.isCompleted)
            ) {
                Text(task.title)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Link(destination: ScribeAppGroup.taskURL(id: task.id)) {
                Text(task.title)
                    .font(.callout)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isOverdue {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if task.priority == .high {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }
}

/// One-line "next meeting" summary, shared by the Today (large) widget.
struct ScribeWidgetMeetingLine: View {

    let meeting: ScribeSharedSnapshot.Meeting
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Text(meeting.title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 4)
            if meeting.isInProgress(at: now) {
                Text("Now")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(meeting.start, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
