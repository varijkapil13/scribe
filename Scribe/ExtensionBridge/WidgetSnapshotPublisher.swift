// Scribe/ExtensionBridge/WidgetSnapshotPublisher.swift
//
// Keeps `widget-snapshot.json` in the App Group container current for the
// ScribeWidgets extension and asks WidgetKit to reload. Triggered (debounced)
// by task changes, calendar refreshes and recording-state changes, plus a
// slow periodic refresh so "today" rolls over at midnight.

import Combine
import Foundation
import GRDB
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {

    private let store: ScribeSharedSnapshotStore
    private let taskStore: TaskStore
    private let debounce: Duration

    private var started = false
    private var taskObservation: AnyDatabaseCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var lastWritten: ScribeSharedSnapshot?

    private static let periodicRefresh: Duration = .seconds(15 * 60)

    init(store: ScribeSharedSnapshotStore, taskStore: TaskStore, debounce: Duration) {
        self.store = store
        self.taskStore = taskStore
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    /// Starts observing the sources and publishes once. Idempotent.
    func start(database: DatabaseQueue) {
        guard !started else { return }
        started = true

        taskObservation = Self.observeTaskChanges(in: database) { [weak self] in
            Task { @MainActor [weak self] in self?.setNeedsPublish() }
        }

        CalendarService.shared.$upcomingEvents
            .dropFirst()
            .sink { [weak self] _ in self?.setNeedsPublish() }
            .store(in: &cancellables)

        let state = AppState.shared
        state.$isTranscribing
            .removeDuplicates()
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.recordingStartedAt = isRecording ? Date() : nil
                self.setNeedsPublish()
            }
            .store(in: &cancellables)
        state.$isStartingSession
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.setNeedsPublish() }
            .store(in: &cancellables)

        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicRefresh)
                guard !Task.isCancelled else { return }
                self?.publishNow()
            }
        }

        publishNow()
    }

    /// (Re)arms the debounce; the snapshot is rebuilt once things settle.
    /// `force` rewrites the file even if the content looks unchanged — used
    /// after draining widget requests, because a widget may have written an
    /// optimistic snapshot the app's cache doesn't know about.
    func setNeedsPublish(force: Bool = false) {
        if force { lastWritten = nil }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }

    // MARK: - Publishing

    func publishNow() {
        let now = Date()
        let tasks: [TodoTask]
        do {
            tasks = try taskStore.fetchTasks(filter: .today, now: now)
        } catch {
            Log.app.error("Widget snapshot: couldn't read today's tasks: \(error.localizedDescription, privacy: .private)")
            return
        }
        let state = AppState.shared
        let isRecording = state.isTranscribing || state.isStartingSession
        let snapshot = Self.makeSnapshot(
            now: now,
            tasks: tasks,
            events: CalendarService.shared.upcomingEvents,
            recording: ScribeSharedSnapshot.RecordingState(
                isRecording: isRecording,
                startedAt: isRecording ? recordingStartedAt : nil
            )
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

    // MARK: - Pure mapping (unit-tested)

    nonisolated static func makeSnapshot(
        now: Date,
        tasks: [TodoTask],
        events: [CalendarEventInfo],
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
        ScribeWidgetSnapshotBuilder.taskItem(task)
    }

    nonisolated static func meeting(_ event: CalendarEventInfo) -> ScribeSharedSnapshot.Meeting {
        // Recurring events share an identifier; the start keeps ids unique.
        ScribeSharedSnapshot.Meeting(
            id: "\(event.id)@\(Int(event.start.timeIntervalSince1970))",
            title: event.title,
            start: event.start,
            end: event.end
        )
    }

    nonisolated static func priority(_ priority: TodoTask.Priority?) -> ScribeSharedSnapshot.Priority? {
        ScribeWidgetSnapshotBuilder.priority(priority)
    }

    /// Pings `onChange` after every committed write to `tasks`.
    /// `nonisolated` so GRDB's change callback isn't a main-actor closure.
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
