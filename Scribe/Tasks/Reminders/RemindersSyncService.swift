#if os(macOS)
import Combine
import Foundation

/// Errors a Reminders sync round can stop with.
enum RemindersSyncRoundError: LocalizedError {
    case accessNotGranted
    case snapshotUnavailable

    var errorDescription: String? {
        switch self {
        case .accessNotGranted:
            return "Scribe doesn't have full access to Reminders."
        case .snapshotUnavailable:
            return "Reminders didn't return its items, so nothing was synced."
        }
    }
}

/// Two-way sync between Scribe tasks and Apple Reminders (macOS).
///
/// A round: snapshot every reminder (EventKit) and every task (GRDB) plus the
/// stored links → `RemindersSyncPlanner.plan` → apply the actions → refresh
/// the touched links. `RemindersSyncScheduler` decides when rounds run; the
/// Settings pane drives `enable()` and shows the published state.
@MainActor
final class RemindersSyncService: ObservableObject {

    static let shared: RemindersSyncService = makeShared()

    /// Arguments passed explicitly (no default arguments evaluated from the
    /// `static let`).
    private static func makeShared() -> RemindersSyncService {
        RemindersSyncService(
            taskStore: TaskStore.shared,
            linkStore: TaskReminderLinkStore(databaseManager: DatabaseManager.shared)
        )
    }

    /// Stored when a stamp is unknown. The Unix epoch rather than
    /// `.distantPast`, which doesn't survive SQLite's date text format well.
    nonisolated static let unknownStamp = Date(timeIntervalSince1970: 0)

    // MARK: - Published state

    @Published private(set) var access: RemindersEventStore.Access
    @Published private(set) var lists: [RemindersListInfo] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastError: String?

    // MARK: - Dependencies

    private let taskStore: TaskStore
    private let linkStore: TaskReminderLinkStore
    /// Lazy so merely observing the service never instantiates EventKit while
    /// the feature is off.
    private lazy var eventStore = RemindersEventStore()

    init(taskStore: TaskStore, linkStore: TaskReminderLinkStore) {
        self.taskStore = taskStore
        self.linkStore = linkStore
        self.access = RemindersEventStore.currentAccess()
    }

    /// Whether a round may run right now.
    var isActive: Bool {
        RemindersSyncSettings.isEnabled && RemindersEventStore.currentAccess() == .granted
    }

    // MARK: - Settings actions

    /// Requests full Reminders access if undecided, then turns the sync on.
    /// Returns whether access is granted.
    @discardableResult
    func enable() async -> Bool {
        if RemindersEventStore.currentAccess() == .notDetermined {
            let granted = await eventStore.requestFullAccess()
            Log.app.info("Reminders access request finished (granted: \(granted, privacy: .public)).")
        }
        refreshAccess()
        UserDefaults.standard.set(true, forKey: RemindersSyncSettings.enabledKey)
        refreshLists()
        return access == .granted
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: RemindersSyncSettings.enabledKey)
    }

    /// Re-reads the authorization status (e.g. back from System Settings).
    func refreshAccess() {
        let current = RemindersEventStore.currentAccess()
        if current != access { access = current }
    }

    /// Reloads the editable Reminders lists (for the Settings pickers).
    func refreshLists() {
        refreshAccess()
        guard access == .granted else {
            if !lists.isEmpty { lists = [] }
            return
        }
        let fresh = eventStore.reminderLists()
        if fresh != lists { lists = fresh }
    }

    /// The list the Inbox currently resolves to (chosen, else default).
    func resolvedInboxListId() -> String? {
        if let chosen = RemindersSyncSettings.inboxListId {
            return lists.contains { $0.id == chosen } ? chosen : nil
        }
        return eventStore.defaultListId()
    }

    /// Forgets every pairing. The next round re-pairs by title + due date, so
    /// nothing is duplicated or deleted.
    func resetLinks() {
        do {
            try linkStore.deleteAllLinks()
            lastSummary = "Pairings cleared."
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Round

    /// Runs one full round. Called by `RemindersSyncScheduler`.
    func sync() async throws {
        guard RemindersSyncSettings.isEnabled else { return }
        refreshAccess()
        guard access == .granted else { throw RemindersSyncRoundError.accessNotGranted }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await runRound()
            lastSyncAt = Date()
            lastSummary = summary
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func runRound() async throws -> String {
        let calendar = Calendar.current
        eventStore.reset()
        refreshLists()

        let settings = (direction: RemindersSyncSettings.direction,
                        mapProjects: RemindersSyncSettings.mapProjectsByName)
        let mapping = RemindersListMapping.resolve(
            projects: try taskStore.fetchProjects(),
            lists: lists,
            inboxListId: resolvedInboxListId(),
            mapProjectsByName: settings.mapProjects
        )

        guard let reminders = await eventStore.fetchReminderSnapshots(calendar: calendar) else {
            throw RemindersSyncRoundError.snapshotUnavailable
        }
        // Read the task side after the (async) reminder fetch so it's as fresh
        // as possible when the plan is applied.
        let input = RemindersSyncPlanInput(
            tasks: try linkStore.fetchAllTasks(),
            reminders: reminders,
            links: try linkStore.fetchAllLinks(),
            mapping: mapping,
            direction: settings.direction,
            // A chosen Inbox list that's gone (account offline, list
            // deleted) means reminders may be missing: never delete tasks then.
            reminderSnapshotIsComplete: !lists.isEmpty
                && (RemindersSyncSettings.inboxListId == nil || mapping.inboxListId != nil)
        )
        let plan = RemindersSyncPlanner.plan(input, calendar: calendar)
        if !plan.suppressedTaskDeletes.isEmpty || !plan.suppressedReminderDeletes.isEmpty {
            Log.app.notice("Reminders sync held back \(plan.suppressedTaskDeletes.count, privacy: .public) task and \(plan.suppressedReminderDeletes.count, privacy: .public) reminder deletions (safety limit).")
        }
        return apply(plan, calendar: calendar)
    }

    // MARK: - Applying a plan

    /// Applies every action, best-effort: a failing step is logged and skipped
    /// (its link is left as-is, so the next round retries it).
    private func apply(_ plan: RemindersSyncPlan, calendar: Calendar) -> String {
        var counts = (exported: 0, imported: 0, updated: 0, deleted: 0, failed: 0)
        /// Pairs to (re)record after the writes: taskId → reminder id.
        var pairsToRecord: [String: String] = [:]
        var pairOrder: [String] = []
        /// Tasks whose recorded stamp must stay old so the next round pushes
        /// their post-write state (a recurring task advanced by completion).
        var keepTaskStamp = Set<String>()

        func record(_ taskId: String, _ reminderId: String) {
            if pairsToRecord[taskId] == nil { pairOrder.append(taskId) }
            pairsToRecord[taskId] = reminderId
        }
        func forget(_ taskId: String) {
            pairsToRecord[taskId] = nil
            do { try linkStore.deleteLink(taskId: taskId) } catch {
                Log.app.error("Reminders sync: dropping a link failed: \(error.localizedDescription, privacy: .private)")
            }
        }

        for action in plan.actions {
            do {
                switch action {
                case let .createReminder(taskId, listId, fields, isCompleted, completionDate):
                    if let newId = try eventStore.createReminder(
                        listId: listId, fields: fields,
                        isCompleted: isCompleted, completionDate: completionDate,
                        calendar: calendar
                    ) {
                        record(taskId, newId)
                        counts.exported += 1
                    }

                case let .updateReminder(reminderId, taskId, moveToListId, fields, includeRecurrence):
                    if try eventStore.updateReminder(
                        id: reminderId, moveToListId: moveToListId, fields: fields,
                        includeRecurrence: includeRecurrence, calendar: calendar
                    ) {
                        record(taskId, reminderId)
                        counts.updated += 1
                    }

                case let .setReminderCompletion(reminderId, taskId, isCompleted, completionDate):
                    if try eventStore.setCompletion(id: reminderId, isCompleted: isCompleted, completionDate: completionDate) {
                        record(taskId, reminderId)
                        counts.updated += 1
                    }

                case let .deleteReminder(reminderId, taskId):
                    _ = try eventStore.removeReminder(id: reminderId)
                    forget(taskId)
                    counts.deleted += 1

                case let .createTask(reminderId, changes, isCompleted):
                    let task = try taskStore.createTask(
                        title: changes.title,
                        notes: changes.notes,
                        projectId: changes.projectId,
                        priority: changes.priority,
                        dueAt: changes.dueAt,
                        recurrenceRule: changes.recurrenceRule
                    )
                    if isCompleted { try taskStore.completeTask(id: task.id, at: Date()) }
                    record(task.id, reminderId)
                    counts.imported += 1

                case let .updateTask(taskId, reminderId, changes):
                    if try applyTaskChanges(changes, to: taskId) {
                        record(taskId, reminderId)
                        counts.updated += 1
                    }

                case let .setTaskCompletion(taskId, reminderId, isCompleted, _):
                    guard let task = try taskStore.fetchTask(id: taskId) else { break }
                    if isCompleted {
                        try taskStore.completeTask(id: taskId, at: Date())
                        // A recurring task doesn't stay completed — it moves to
                        // its next due date. Leave its stamp old so the next
                        // round pushes that (reopened, rescheduled) state back.
                        if task.recurrenceRule != nil && task.dueAt != nil { keepTaskStamp.insert(taskId) }
                    } else {
                        if task.cancelledAt != nil { try taskStore.uncancelTask(id: taskId) }
                        if task.completedAt != nil { try taskStore.uncompleteTask(id: taskId) }
                    }
                    record(taskId, reminderId)
                    counts.updated += 1

                case let .deleteTask(taskId, _):
                    try taskStore.deleteTask(id: taskId)
                    forget(taskId)
                    counts.deleted += 1

                case let .link(taskId, reminderId):
                    record(taskId, reminderId)

                case let .unlink(taskId):
                    forget(taskId)
                }
            } catch {
                counts.failed += 1
                Log.app.error("Reminders sync step failed: \(error.localizedDescription, privacy: .private)")
            }
        }

        for taskId in pairOrder {
            guard let reminderId = pairsToRecord[taskId] else { continue }
            recordLink(taskId: taskId, reminderId: reminderId, keepTaskStamp: keepTaskStamp.contains(taskId))
        }

        var parts: [String] = []
        if counts.exported > 0 { parts.append("\(counts.exported) exported") }
        if counts.imported > 0 { parts.append("\(counts.imported) imported") }
        if counts.updated > 0 { parts.append("\(counts.updated) updated") }
        if counts.deleted > 0 { parts.append("\(counts.deleted) deleted") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        return parts.isEmpty ? "Up to date." : parts.joined(separator: ", ") + "."
    }

    /// Applies synced fields onto the current row (so unsynced fields — tags,
    /// pin, reminder time, sort order — survive). Returns false if it's gone.
    private func applyTaskChanges(_ changes: RemindersSyncTaskChanges, to taskId: String) throws -> Bool {
        guard var task = try taskStore.fetchTask(id: taskId) else { return false }
        if task.projectId != changes.projectId {
            // moveTask also appends it at the bottom of the destination.
            try taskStore.moveTask(id: taskId, toProject: changes.projectId)
            guard let moved = try taskStore.fetchTask(id: taskId) else { return false }
            task = moved
        }
        let updated = changes.applied(to: task)
        if updated != task {
            try taskStore.updateTask(updated)
        }
        return true
    }

    /// Records the pair with both sides' current stamps.
    private func recordLink(taskId: String, reminderId: String, keepTaskStamp: Bool) {
        do {
            guard let task = try taskStore.fetchTask(id: taskId),
                  let stamp = eventStore.stamp(id: reminderId) else { return }
            let previous = try linkStore.link(forTaskId: taskId)
            let taskStamp: Date? = keepTaskStamp ? previous?.lastSyncedTaskUpdatedAt : task.updatedAt
            try linkStore.upsert(TaskReminderLink(
                taskId: taskId,
                calendarItemIdentifier: stamp.calendarItemIdentifier,
                externalIdentifier: stamp.externalIdentifier,
                lastSyncedTaskUpdatedAt: taskStamp ?? Self.unknownStamp,
                lastSyncedReminderModifiedAt: stamp.modifiedAt
            ))
        } catch {
            Log.app.error("Reminders sync: recording a link failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
#endif
