// ScribeiOS/System/IOSWidgetSnapshotPublisher.swift
//
// iOS counterpart of the Mac's WidgetSnapshotPublisher: keeps
// `widget-snapshot.json` in the App Group current for the ScribeiOSWidgets
// extension and reloads its timelines. Triggered (debounced) by task changes
// and recording-state changes, written immediately when a scene goes to the
// background, plus a slow periodic refresh while the app runs. The mapping
// is the portable ScribeWidgetSnapshotBuilder; meetings come straight from
// EventKit (only when the user already granted calendar access — this never
// prompts).

import EventKit
import Foundation
import GRDB
import WidgetKit

@MainActor
final class IOSWidgetSnapshotPublisher {

    private let store: ScribeSharedSnapshotStore
    private let taskStore: TaskStore
    private let debounce: Duration

    private var started = false
    private var taskObservation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var lastWritten: ScribeSharedSnapshot?
    private var observedRecordingStart: Date?
    private lazy var eventStore = EKEventStore()

    private static let periodicRefresh: Duration = .seconds(15 * 60)
    /// How far ahead meetings are read (the widgets show the next few).
    private static let meetingLookahead: TimeInterval = 24 * 60 * 60

    init(store: ScribeSharedSnapshotStore, taskStore: TaskStore, debounce: Duration) {
        self.store = store
        self.taskStore = taskStore
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    func start(database: DatabaseQueue) {
        guard !started else { return }
        started = true

        taskObservation = Self.observeTaskChanges(in: database) { [weak self] in
            Task { @MainActor [weak self] in self?.setNeedsPublish(force: false) }
        }

        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicRefresh)
                guard !Task.isCancelled else { return }
                self?.publishNow(force: false)
            }
        }

        publishNow(force: true)
    }

    /// (Re)arms the debounce. `force` rewrites even when the content looks
    /// unchanged (a widget may have written an optimistic snapshot).
    func setNeedsPublish(force: Bool) {
        if force { lastWritten = nil }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.publishNow(force: false)
        }
    }

    // MARK: - Publishing

    func publishNow(force: Bool) {
        if force { lastWritten = nil }
        debounceTask?.cancel()
        let now = Date()
        let tasks: [TodoTask]
        do {
            tasks = try taskStore.fetchTasks(filter: .today, now: now)
        } catch {
            Log.app.error("Widget snapshot: couldn't read today's tasks: \(error.localizedDescription, privacy: .private)")
            return
        }
        let snapshot = ScribeWidgetSnapshotBuilder.snapshot(
            now: now,
            tasks: tasks,
            events: upcomingEvents(now: now),
            recording: recordingState(now: now)
        )
        if let lastWritten, lastWritten.hasSameContent(as: snapshot) { return }
        do {
            try store.write(snapshot)
            lastWritten = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Log.app.error("Widget snapshot: write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Sources

    private func recordingState(now: Date) -> ScribeSharedSnapshot.RecordingState {
        guard let control = ScribeRecordingControlRegistry.current, control.isRecordingActive else {
            observedRecordingStart = nil
            return .idle
        }
        if observedRecordingStart == nil { observedRecordingStart = now }
        return ScribeSharedSnapshot.RecordingState(
            isRecording: true,
            startedAt: control.activeRecordingStartedAt ?? observedRecordingStart
        )
    }

    /// Timed and all-day events from now (in-progress ones included) to a day
    /// ahead. Empty without full calendar access.
    private func upcomingEvents(now: Date) -> [ScribeWidgetSnapshotBuilder.Event] {
        guard Self.hasCalendarAccess() else { return [] }
        return Self.readEvents(
            from: eventStore,
            start: now.addingTimeInterval(-Self.meetingLookahead / 2),
            end: now.addingTimeInterval(Self.meetingLookahead)
        )
    }

    /// Isolated EventKit authorization check (full access, iOS 17+).
    nonisolated static func hasCalendarAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Isolated EventKit read: if an EventKit signature changes, only this
    /// function needs fixing.
    nonisolated static func readEvents(from store: EKEventStore, start: Date, end: Date) -> [ScribeWidgetSnapshotBuilder.Event] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event -> ScribeWidgetSnapshotBuilder.Event? in
            // Typed optionals, as CalendarService does: EventKit's
            // implicitly-unwrapped properties can be nil.
            let startDate: Date? = event.startDate
            let endDate: Date? = event.endDate
            guard let eventStart = startDate, let eventEnd = endDate else { return nil }
            let identifier: String? = event.eventIdentifier
            let rawTitle: String? = event.title
            let title = rawTitle ?? ""
            return ScribeWidgetSnapshotBuilder.Event(
                id: identifier ?? UUID().uuidString,
                title: title.isEmpty ? "Untitled event" : title,
                start: eventStart,
                end: eventEnd,
                isAllDay: event.isAllDay
            )
        }
    }

    /// Pings `onChange` after every committed write to `tasks`.
    nonisolated private static func observeTaskChanges(
        in database: DatabaseQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: TodoTask.all())
        return observation.start(
            in: database,
            onError: { error in
                Log.storage.error("Widget snapshot observation failed: \(error.localizedDescription, privacy: .private)")
            },
            onChange: { _ in onChange() }
        )
    }
}
