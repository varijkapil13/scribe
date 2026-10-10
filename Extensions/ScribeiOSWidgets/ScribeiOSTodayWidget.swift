// Extensions/ScribeiOSWidgets/ScribeiOSTodayWidget.swift
//
// "Today" on iPhone / iPad: the day's tasks with tappable completion circles
// (`ToggleScribeWidgetTaskIntent` queues the change in the App Group; the app
// applies it when it next runs), on the Home Screen (small / medium / large),
// in StandBy (small), on the iPad's extra-large size (tasks beside the day's
// meetings) and on the Lock Screen (circular progress, rectangular list,
// inline count). Task titles deep-link to the task.

import AppIntents
import SwiftUI
import WidgetKit

struct ScribeiOSTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ScribeiOSWidgetKinds.today,
            provider: ScribeSnapshotTimelineProvider()
        ) { entry in
            ScribeiOSTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's tasks from Scribe. Check them off right from the widget.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct ScribeiOSTodayWidgetView: View {

    let entry: ScribeWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var allTasks: [ScribeSharedSnapshot.TaskItem] { entry.snapshot.tasks }

    private var openCount: Int { allTasks.filter { !$0.isCompleted }.count }

    private var rowLimit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 4
        default: return ScribeSharedSnapshot.maxTasks
        }
    }

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
        case .systemExtraLarge:
            extraLarge
        default:
            home
        }
    }

    // MARK: - Home Screen / StandBy

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Today", systemImage: "sun.max")
                    .font(.headline)
                    .widgetAccentable()
                Spacer(minLength: 4)
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            if allTasks.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing due today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(allTasks.prefix(rowLimit))) { task in
                    ScribeiOSWidgetTaskRow(task: task, now: entry.date, linksTitle: family != .systemSmall)
                }
                Spacer(minLength: 0)
            }
            if family == .systemLarge, let meeting = entry.snapshot.nextMeeting(at: entry.date) {
                Divider()
                ScribeiOSWidgetMeetingLine(meeting: meeting, now: entry.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - iPad extra large

    private var upcomingMeetings: [ScribeSharedSnapshot.Meeting] {
        entry.snapshot.meetings.filter { $0.end > entry.date }
    }

    private var extraLarge: some View {
        HStack(alignment: .top, spacing: 20) {
            home
            VStack(alignment: .leading, spacing: 8) {
                Label("Meetings", systemImage: "calendar")
                    .font(.headline)
                    .widgetAccentable()
                if upcomingMeetings.isEmpty {
                    Text("No more meetings in the next 24 hours")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(upcomingMeetings) { meeting in
                        ScribeiOSWidgetMeetingLine(meeting: meeting, now: entry.date)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Lock Screen

    private var circular: some View {
        let total = allTasks.count
        let done = total - openCount
        return Gauge(value: Double(done), in: 0...Double(max(total, 1))) {
            Image(systemName: "checklist")
        } currentValueLabel: {
            Text("\(openCount)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private var rectangular: some View {
        let heading: String = openCount == 0 ? "All done today" : "Today · \(openCount)"
        return VStack(alignment: .leading, spacing: 2) {
            Label(heading, systemImage: "checklist")
                .font(.headline)
                .widgetAccentable()
            ForEach(Array(allTasks.filter { !$0.isCompleted }.prefix(2))) { task in
                Text(task.title)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        let text: String = openCount == 1 ? "1 task today" : "\(openCount) tasks today"
        return Label(text, systemImage: "checklist")
    }
}

/// A task with a completion button (interactive on the Home Screen and in
/// StandBy).
struct ScribeiOSWidgetTaskRow: View {

    let task: ScribeSharedSnapshot.TaskItem
    let now: Date
    /// Small widgets are one tap target; larger ones link each title.
    let linksTitle: Bool

    private var isOverdue: Bool {
        guard let due = task.due, !task.isCompleted else { return false }
        return due < Calendar.current.startOfDay(for: now)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleScribeWidgetTaskIntent(taskId: task.id, isCompleted: !task.isCompleted)) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark not done" : "Mark done")

            if linksTitle {
                Link(destination: ScribeAppGroup.taskURL(id: task.id)) { title }
            } else {
                title
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

    private var title: some View {
        Text(task.title)
            .font(.callout)
            .strikethrough(task.isCompleted)
            .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
            .lineLimit(1)
    }
}

/// One-line "next meeting" summary (Today large).
struct ScribeiOSWidgetMeetingLine: View {

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
