// Scribe/ExtensionBridge/ScribeWidgetSnapshotBuilder.swift
//
// Pure TodoTask / calendar → `ScribeSharedSnapshot` mapping shared by the
// macOS `WidgetSnapshotPublisher` and the iOS publisher
// (ScribeiOS/System/IOSWidgetSnapshotPublisher.swift). Portable and
// Foundation-only (compiled into both apps; unit-tested).

import Foundation

enum ScribeWidgetSnapshotBuilder {

    /// A calendar event as the builder needs it (the platforms read events
    /// from different sources: CalendarService on macOS, EventKit directly
    /// on iOS).
    struct Event: Equatable, Sendable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool

        init(id: String, title: String, start: Date, end: Date, isAllDay: Bool) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
        }
    }

    /// The snapshot for `now`: today's tasks (cancelled ones dropped, order
    /// kept) and the timed (not all-day) meetings.
    nonisolated static func snapshot(
        now: Date,
        tasks: [TodoTask],
        events: [Event],
        recording: ScribeSharedSnapshot.RecordingState
    ) -> ScribeSharedSnapshot {
        ScribeSharedSnapshot.make(
            now: now,
            tasks: tasks.filter { !$0.isCancelled }.map(taskItem),
            meetings: events.filter { !$0.isAllDay }.map(meeting),
            recording: recording
        )
    }

    nonisolated static func taskItem(_ task: TodoTask) -> ScribeSharedSnapshot.TaskItem {
        ScribeSharedSnapshot.TaskItem(
            id: task.id,
            title: task.title,
            due: task.dueAt,
            priority: priority(task.priority),
            isCompleted: task.isCompleted
        )
    }

    /// Recurring events share an identifier; the start keeps ids unique.
    nonisolated static func meeting(_ event: Event) -> ScribeSharedSnapshot.Meeting {
        ScribeSharedSnapshot.Meeting(
            id: "\(event.id)@\(Int(event.start.timeIntervalSince1970))",
            title: event.title,
            start: event.start,
            end: event.end
        )
    }

    nonisolated static func priority(_ priority: TodoTask.Priority?) -> ScribeSharedSnapshot.Priority? {
        switch priority {
        case .high?:   return .high
        case .medium?: return .medium
        case .low?:    return .low
        case nil:      return nil
        }
    }
}
