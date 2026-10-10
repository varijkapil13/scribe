// ScribeiOS/System/ScribeTodayAgendaIntent.swift
//
// "Today in Scribe": answers with a dialog and a snippet listing today's open
// tasks and the next meeting (Siri, Spotlight, the Shortcuts app). Read-only;
// tapping a row isn't needed — the snippet is a glanceable summary.

import AppIntents
import EventKit
import SwiftUI

struct ScribeTodayAgendaIntent: AppIntent {

    static var title: LocalizedStringResource { "Today in Scribe" }

    static var description: IntentDescription {
        IntentDescription("Shows today's open tasks and your next meeting from Scribe.")
    }

    init() {}

    /// Main actor: the snippet is a SwiftUI view (main-actor isolated).
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let now = Date()
        let tasks = try ScribeIntentsData.live.todayTasks(now: now).filter { !$0.isCompleted }
        let rows = tasks.prefix(6).map { task in
            ScribeAgendaSnippetView.Row(
                id: task.id,
                title: ScribeIntentsText.displayTitle(task.title, fallback: "Untitled task"),
                isOverdue: (task.dueAt ?? now) < Calendar.current.startOfDay(for: now)
            )
        }
        let meeting = Self.nextMeeting(now: now)
        let dialog: IntentDialog
        switch tasks.count {
        case 0:  dialog = "You have no tasks for today."
        case 1:  dialog = "You have 1 task for today."
        default: dialog = "You have \(tasks.count) tasks for today."
        }
        let view = ScribeAgendaSnippetView(rows: Array(rows), remaining: max(0, tasks.count - rows.count), meeting: meeting)
        return Self.snippetResult(dialog: dialog, view: view)
    }

    /// Isolated so a change in the snippet-result API is a one-line fix.
    private static func snippetResult(dialog: IntentDialog, view: ScribeAgendaSnippetView) -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        .result(dialog: dialog, view: view)
    }

    /// The next timed meeting that hasn't ended (needs calendar access
    /// granted earlier; never prompts).
    private static func nextMeeting(now: Date) -> ScribeSharedSnapshot.Meeting? {
        guard IOSWidgetSnapshotPublisher.hasCalendarAccess() else { return nil }
        let events = IOSWidgetSnapshotPublisher.readEvents(
            from: EKEventStore(),
            start: now.addingTimeInterval(-12 * 60 * 60),
            end: now.addingTimeInterval(24 * 60 * 60)
        )
        let snapshot = ScribeWidgetSnapshotBuilder.snapshot(now: now, tasks: [], events: events, recording: .idle)
        return snapshot.nextMeeting(at: now)
    }
}

/// The snippet: a short task list and the next meeting.
struct ScribeAgendaSnippetView: View {

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let isOverdue: Bool
    }

    let rows: [Row]
    let remaining: Int
    let meeting: ScribeSharedSnapshot.Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Label("Nothing due today", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .foregroundStyle(row.isOverdue ? Color.red : Color.secondary)
                        Text(row.title)
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                }
                if remaining > 0 {
                    Text("+\(remaining) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let meeting {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text(meeting.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(meeting.start, style: .time)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
