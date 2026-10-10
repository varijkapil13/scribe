// Extensions/ScribeWidgets/ScribeWidgetTimeline.swift
//
// Timeline provider shared by the Today and Next Meeting widgets: reads the
// snapshot the app writes into the App Group and schedules extra entries at
// meeting boundaries so "next meeting" advances on its own.

import Foundation
import WidgetKit

struct ScribeWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: ScribeSharedSnapshot
}

struct ScribeSnapshotTimelineProvider: TimelineProvider {

    /// How long until WidgetKit should ask again even if the app never
    /// reloads us (the app reloads on every change it publishes).
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ScribeWidgetEntry {
        let now = Date()
        return ScribeWidgetEntry(date: now, snapshot: ScribeWidgetSamples.sample(now: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (ScribeWidgetEntry) -> Void) {
        let now = Date()
        let stored = ScribeSharedSnapshotStore.appGroup()?.read()
        let snapshot: ScribeSharedSnapshot
        if let stored {
            snapshot = stored
        } else if context.isPreview {
            snapshot = ScribeWidgetSamples.sample(now: now)
        } else {
            snapshot = .empty(at: now)
        }
        completion(ScribeWidgetEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScribeWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = ScribeSharedSnapshotStore.appGroup()?.read() ?? .empty(at: now)
        let entries = Self.entryDates(for: snapshot, now: now)
            .map { ScribeWidgetEntry(date: $0, snapshot: snapshot) }
        let next = now.addingTimeInterval(Self.refreshInterval)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    /// `now` plus each upcoming meeting start / end (deduplicated, sorted),
    /// so the widgets switch from "next" to "now" to the following meeting
    /// without waiting for a reload.
    static func entryDates(for snapshot: ScribeSharedSnapshot, now: Date) -> [Date] {
        var dates: Set<Date> = [now]
        for meeting in snapshot.meetings {
            if meeting.start > now { dates.insert(meeting.start) }
            if meeting.end > now { dates.insert(meeting.end) }
        }
        return dates.sorted()
    }
}

/// Sample content for the widget gallery and placeholders.
enum ScribeWidgetSamples {
    static func sample(now: Date) -> ScribeSharedSnapshot {
        ScribeSharedSnapshot.make(
            now: now,
            tasks: [
                .init(id: "sample-1", title: "Review meeting notes", due: now, priority: .high, isCompleted: false),
                .init(id: "sample-2", title: "Send follow-up email", due: now, priority: nil, isCompleted: false),
                .init(id: "sample-3", title: "Draft project plan", due: nil, priority: .medium, isCompleted: true),
            ],
            meetings: [
                .init(
                    id: "sample-meeting",
                    title: "Weekly sync",
                    start: now.addingTimeInterval(25 * 60),
                    end: now.addingTimeInterval(55 * 60)
                ),
            ],
            recording: .idle
        )
    }
}
