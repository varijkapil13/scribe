import Combine
import EventKit
import Foundation

/// A calendar the user can pick for time blocks.
struct TaskCalendarChoice: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
}

/// Time blocking: mirrors scheduled task blocks (a due time + duration) into a
/// calendar the user chooses, as EventKit events. Off by default ("Write
/// scheduled tasks to calendar" in Settings → Calendar) and only active while
/// the calendar integration has full access.
///
/// Decisions come from the pure `TaskCalendarMirrorPlanner`; this type only
/// executes them. The `task_calendar_blocks` table is the sole record of which
/// events Scribe created — an event whose identifier isn't recorded there is
/// never modified or deleted.
@MainActor
final class TaskCalendarMirrorService: ObservableObject {

    static let shared = TaskCalendarMirrorService()

    // MARK: - Settings keys

    /// "Write scheduled tasks to calendar". Default off.
    static let enabledKey = "taskCalendarBlocksEnabled"
    /// `EKCalendar.calendarIdentifier` blocks are written to.
    static let calendarIdKey = "taskCalendarBlocksCalendarId"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var selectedCalendarId: String? {
        let raw = UserDefaults.standard.string(forKey: calendarIdKey) ?? ""
        return raw.isEmpty ? nil : raw
    }

    // MARK: - Published

    /// Calendars that accept new events (for the Settings picker).
    @Published private(set) var availableCalendars: [TaskCalendarChoice] = []
    /// Last failure, shown under the setting. Nil after a clean pass.
    @Published private(set) var lastError: String?

    // MARK: - Private

    private let linkStore: TaskCalendarBlockLinkStore
    /// Created on first use so EventKit is never touched while the feature
    /// (and the calendar integration) is off.
    private var writer: TaskCalendarEventWriter?
    private var taskCancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var pendingSync: Task<Void, Never>?
    private var lastSettings: String?

    private static let debounce: Duration = .seconds(1)

    private init() {
        linkStore = TaskCalendarBlockLinkStore(databaseManager: DatabaseManager.shared)
    }

    // MARK: - Lifecycle

    /// Called once at launch (after `CalendarService.start()`).
    func start() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsMaybeChanged() }
            }
        }
        if taskCancellable == nil {
            // Any task change (edit, completion, delete) re-plans. Active tasks
            // are only the trigger; the pass itself reads every row.
            taskCancellable = TaskStore.shared.observeTasks(filter: .all)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] _ in self?.scheduleSync() })
        }
        settingsMaybeChanged()
    }

    /// Whether EventKit may be used right now.
    private var hasAccess: Bool {
        CalendarService.isEnabled && CalendarService.shared.accessState == .granted
    }

    /// Re-reads the writable calendars (Settings → Calendar).
    func reloadCalendars() {
        guard hasAccess else {
            availableCalendars = []
            return
        }
        availableCalendars = ensureWriter().writableCalendars()
    }

    /// Identifiers of events Scribe created (the planner grid hides them so a
    /// block isn't drawn twice).
    func mirroredEventIdentifiers() -> Set<String> {
        (try? linkStore.mirroredEventIdentifiers()) ?? []
    }

    // MARK: - Sync

    private func settingsMaybeChanged() {
        let settings = "\(Self.isEnabled)|\(Self.selectedCalendarId ?? "")|\(CalendarService.isEnabled)"
        guard settings != lastSettings else { return }
        lastSettings = settings
        scheduleSync()
    }

    /// Debounced pass (task edits arrive in bursts while typing).
    func scheduleSync() {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            self?.syncNow()
        }
    }

    /// One reconciliation pass: plan, then execute each action.
    func syncNow() {
        CalendarService.shared.refreshAccessState()
        guard CalendarService.shared.accessState == .granted else { return }
        do {
            let links = try linkStore.fetchAllLinks()
            let enabled = Self.isEnabled && CalendarService.isEnabled
            // Nothing to write and nothing of ours to clean up: stay off EventKit.
            guard enabled || !links.isEmpty else { return }
            let writer = ensureWriter()
            let calendar = Calendar.current
            let now = Date()
            let window = TaskCalendarMirrorConfiguration.window(around: now, calendar: calendar)
            let configuration = TaskCalendarMirrorConfiguration(
                isEnabled: enabled,
                calendarId: Self.selectedCalendarId,
                windowStart: window.start,
                windowEnd: window.end
            )
            let existing = Set(links.map(\.eventIdentifier).filter { writer.eventExists(identifier: $0) })
            let actions = TaskCalendarMirrorPlanner.plan(
                tasks: try linkStore.fetchAllTasks(),
                links: links,
                existingEventIds: existing,
                configuration: configuration,
                calendar: calendar
            )
            var failure: String?
            for action in actions {
                if let message = execute(action, writer: writer, calendarId: configuration.calendarId) {
                    failure = message
                }
            }
            lastError = failure
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Time blocking pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs one action. Returns an error message on failure.
    private func execute(_ action: TaskCalendarMirrorAction,
                         writer: TaskCalendarEventWriter,
                         calendarId: String?) -> String? {
        do {
            switch action {
            case .create(let draft):
                guard let calendarId else { return nil }
                guard let identifier = try writer.createEvent(draft, calendarId: calendarId) else {
                    return "The calendar chosen for time blocks is no longer available."
                }
                do {
                    try linkStore.upsert(TaskCalendarBlockLink(
                        taskId: draft.taskId, eventIdentifier: identifier, calendarId: calendarId,
                        lastStart: draft.start, lastEnd: draft.end, lastTitle: draft.title))
                } catch {
                    // An event without a link row would never be updated or
                    // removed, and the next pass would write it again: take
                    // back the event just created.
                    try? writer.deleteEvent(identifier: identifier)
                    throw error
                }
            case .update(let link, let draft):
                if try writer.updateEvent(identifier: link.eventIdentifier, with: draft) {
                    var updated = link
                    updated.lastStart = draft.start
                    updated.lastEnd = draft.end
                    updated.lastTitle = draft.title
                    try linkStore.upsert(updated)
                } else {
                    try linkStore.deleteLink(taskId: link.taskId)
                }
            case .delete(let link):
                try writer.deleteEvent(identifier: link.eventIdentifier)
                try linkStore.deleteLink(taskId: link.taskId)
            case .forget(let link):
                try linkStore.deleteLink(taskId: link.taskId)
            }
            return nil
        } catch {
            Log.app.error("Time blocking action failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    private func ensureWriter() -> TaskCalendarEventWriter {
        if let writer { return writer }
        let created = TaskCalendarEventWriter()
        writer = created
        return created
    }
}

// MARK: - EventKit wrapper

enum TaskCalendarMirrorError: LocalizedError {
    case missingEventIdentifier

    var errorDescription: String? {
        switch self {
        case .missingEventIdentifier:
            return "Calendar didn't return an identifier for a new time block."
        }
    }
}

/// The EventKit calls time blocking makes, kept in one small type (outside any
/// actor, like `CalendarStore`). Every method that changes an event takes the
/// identifier from a `task_calendar_blocks` row — callers never pass an event
/// they found any other way.
final class TaskCalendarEventWriter: @unchecked Sendable {

    private let store = EKEventStore()

    func writableCalendars() -> [TaskCalendarChoice] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { calendar in
                let source: EKSource? = calendar.source
                return TaskCalendarChoice(id: calendar.calendarIdentifier,
                                          title: calendar.title,
                                          sourceTitle: source?.title ?? "")
            }
            .sorted { a, b in
                a.sourceTitle != b.sourceTitle ? a.sourceTitle < b.sourceTitle : a.title < b.title
            }
    }

    func eventExists(identifier: String) -> Bool {
        store.event(withIdentifier: identifier) != nil
    }

    /// Writes a new event. Returns its identifier, or nil when the calendar
    /// is missing or read-only.
    func createEvent(_ draft: TaskCalendarBlockDraft, calendarId: String) throws -> String? {
        guard let calendar = store.calendar(withIdentifier: calendarId),
              calendar.allowsContentModifications else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(draft, to: event)
        event.notes = "Time block scheduled in Scribe."
        event.url = ScribeDeepLink.task(id: draft.taskId).url
        try store.save(event, span: .thisEvent, commit: true)
        // Typed as optional: the SDK may import this as implicitly unwrapped.
        let rawIdentifier: String? = event.eventIdentifier
        guard let identifier = rawIdentifier, !identifier.isEmpty else {
            // Can't be recorded in `task_calendar_blocks`, so it could never
            // be updated or removed later: undo the write instead of leaving
            // an untracked event (and a duplicate on every later pass).
            try? store.remove(event, span: .thisEvent, commit: true)
            throw TaskCalendarMirrorError.missingEventIdentifier
        }
        return identifier
    }

    /// Moves / retitles the event. Returns false when it no longer exists.
    func updateEvent(identifier: String, with draft: TaskCalendarBlockDraft) throws -> Bool {
        guard let event = store.event(withIdentifier: identifier) else { return false }
        apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return true
    }

    /// Deletes the event (no-op when it's already gone).
    func deleteEvent(identifier: String) throws {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func apply(_ draft: TaskCalendarBlockDraft, to event: EKEvent) {
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = false
    }
}
