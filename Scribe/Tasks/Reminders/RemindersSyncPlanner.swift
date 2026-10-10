import Foundation

/// Everything one planning pass looks at.
struct RemindersSyncPlanInput {
    /// Every Scribe task row (completed / cancelled included).
    var tasks: [TodoTask]
    /// Every reminder snapshot (all lists, completed included).
    var reminders: [RemindersSyncReminder]
    /// Every stored task ↔ reminder pairing.
    var links: [TaskReminderLink]
    var mapping: RemindersListMapping
    var direction: RemindersSyncDirection
    /// False when the adapter has reason to doubt the reminder snapshot is
    /// complete (e.g. the chosen Inbox list is missing — an account may be
    /// offline). Every task deletion is then held back.
    var reminderSnapshotIsComplete: Bool

    init(
        tasks: [TodoTask],
        reminders: [RemindersSyncReminder],
        links: [TaskReminderLink],
        mapping: RemindersListMapping,
        direction: RemindersSyncDirection,
        reminderSnapshotIsComplete: Bool
    ) {
        self.tasks = tasks
        self.reminders = reminders
        self.links = links
        self.mapping = mapping
        self.direction = direction
        self.reminderSnapshotIsComplete = reminderSnapshotIsComplete
    }
}

/// Decides what one Scribe ↔ Apple Reminders sync round does. Pure: no
/// EventKit, no database, no clock — just snapshots in, actions out.
///
/// Rules:
/// - **Linked pairs** (a `TaskReminderLink` exists): each side counts as
///   changed when its modification stamp differs from the one recorded in
///   the link. One side changed → it overwrites the other; both changed → the
///   newer stamp wins (last writer wins). Only fields that actually differ
///   produce writes, so echoes of our own writes settle into no-ops.
/// - **Tombstone-safe deletes**: a side is deleted only when its partner
///   vanished AND a link proves they were paired. If the surviving side was
///   edited after the last sync, the edit wins and the partner is recreated
///   instead. A finished (completed / "Won't do") task is never deleted
///   because its reminder vanished — that's usually "Clear Completed" in
///   Reminders — it's just unpaired. A burst of deletions (or an empty
///   Reminders snapshot) is held back entirely — see `exceedsDeleteSafetyLimit`.
/// - **Unlinked items** (including the very first sync) never delete
///   anything: incomplete items in mapped lists/projects are paired when title
///   and due date match (filling only empty fields), otherwise imported or
///   exported.
/// - **Direction**: import-only never writes reminders; export-only never
///   writes tasks.
enum RemindersSyncPlanner {

    /// Stamps within this many seconds of the recorded one count as unchanged
    /// (SQLite stores dates at millisecond precision; EventKit doesn't).
    static let changeTolerance: TimeInterval = 1

    /// Deletions beyond this many are only allowed when they're also at most
    /// half of all links.
    static let deleteSafetyFloor = 5

    /// True when `deletes` out of `linkCount` linked pairs looks like a broken
    /// snapshot (an unmounted account, a deleted list) rather than intent.
    static func exceedsDeleteSafetyLimit(deletes: Int, linkCount: Int) -> Bool {
        deletes > deleteSafetyFloor && deletes * 2 > linkCount
    }

    static func plan(_ input: RemindersSyncPlanInput, calendar: Calendar) -> RemindersSyncPlan {
        let tasksById = Dictionary(input.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remindersById = Dictionary(
            input.reminders.map { ($0.calendarItemIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // External identifiers are only trusted when unique (recurring
        // reminders' completed copies can share one).
        var remindersByExternal: [String: [RemindersSyncReminder]] = [:]
        for reminder in input.reminders {
            if let ext = reminder.externalIdentifier, !ext.isEmpty {
                remindersByExternal[ext, default: []].append(reminder)
            }
        }

        let links = input.links.sorted { $0.taskId < $1.taskId }
        var claimedTasks = Set<String>()
        var claimedReminders = Set<String>()

        // Pass 1: resolve links by identifier; pass 2: fall back to the
        // external identifier for links whose identifier no longer resolves.
        var resolved: [String: RemindersSyncReminder] = [:]   // taskId → reminder
        var ambiguous = Set<String>()                         // taskIds to skip
        for link in links {
            claimedTasks.insert(link.taskId)
            guard let reminder = remindersById[link.calendarItemIdentifier] else { continue }
            if claimedReminders.contains(reminder.calendarItemIdentifier) {
                ambiguous.insert(link.taskId)
                continue
            }
            claimedReminders.insert(reminder.calendarItemIdentifier)
            resolved[link.taskId] = reminder
        }
        for link in links where resolved[link.taskId] == nil && !ambiguous.contains(link.taskId) {
            guard let ext = link.externalIdentifier, !ext.isEmpty,
                  let candidates = remindersByExternal[ext], let reminder = candidates.first else { continue }
            if candidates.count > 1 {
                // Several reminders share the identifier: can't tell which
                // is ours, so leave the pair (and them) alone rather than
                // guess — or conclude it was deleted.
                ambiguous.insert(link.taskId)
                for candidate in candidates { claimedReminders.insert(candidate.calendarItemIdentifier) }
                continue
            }
            if claimedReminders.contains(reminder.calendarItemIdentifier) {
                ambiguous.insert(link.taskId)
                continue
            }
            claimedReminders.insert(reminder.calendarItemIdentifier)
            resolved[link.taskId] = reminder
        }

        var actions: [RemindersSyncAction] = []
        for link in links where !ambiguous.contains(link.taskId) {
            actions += planLinked(
                link: link,
                task: tasksById[link.taskId],
                reminder: resolved[link.taskId],
                input: input,
                calendar: calendar
            )
        }

        actions += planUnlinked(
            tasks: input.tasks.filter { !claimedTasks.contains($0.id) },
            reminders: input.reminders.filter { !claimedReminders.contains($0.calendarItemIdentifier) },
            input: input,
            calendar: calendar
        )

        return applySafetyGuard(actions, input: input)
    }

    // MARK: - Linked pairs

    private static func planLinked(
        link: TaskReminderLink,
        task: TodoTask?,
        reminder: RemindersSyncReminder?,
        input: RemindersSyncPlanInput,
        calendar: Calendar
    ) -> [RemindersSyncAction] {
        let direction = input.direction
        switch (task, reminder) {
        case (nil, nil):
            return [.unlink(taskId: link.taskId)]

        case (let task?, nil):
            // The reminder vanished from Reminders.
            let edited = changed(task.updatedAt, since: link.lastSyncedTaskUpdatedAt)
            let listId = input.mapping.listId(forProjectId: task.projectId)
            if !direction.writesTasks {
                // Export-only: never delete the task. Re-export only if it was
                // edited since (the edit wins); otherwise the link stays as a
                // tombstone so the task isn't re-exported over and over.
                if edited, let listId {
                    return [recreateReminder(for: task, listId: listId, calendar: calendar)]
                }
                return []
            }
            if edited {
                if direction.writesReminders, let listId {
                    return [recreateReminder(for: task, listId: listId, calendar: calendar)]
                }
                return [.unlink(taskId: task.id)]
            }
            if RemindersFieldMapping.isDone(task) {
                // A finished reminder disappearing is usually Reminders'
                // "Clear Completed" housekeeping, not a request to erase the
                // task's history in Scribe: keep the task, drop the pairing.
                return [.unlink(taskId: task.id)]
            }
            return [.deleteTask(taskId: task.id, calendarItemIdentifier: link.calendarItemIdentifier)]

        case (nil, let reminder?):
            // The task vanished from Scribe.
            let edited = changed(reminder.effectiveModifiedAt, since: link.lastSyncedReminderModifiedAt)
            let target = input.mapping.projectTarget(forListId: reminder.listId)
            if !direction.writesReminders {
                if edited, let target {
                    return [recreateTask(from: reminder, target: target, calendar: calendar)]
                }
                return []
            }
            if edited {
                if direction.writesTasks, let target {
                    return [recreateTask(from: reminder, target: target, calendar: calendar)]
                }
                return [.unlink(taskId: link.taskId)]
            }
            return [.deleteReminder(calendarItemIdentifier: reminder.calendarItemIdentifier, taskId: link.taskId)]

        case (let task?, let reminder?):
            return reconcile(task: task, reminder: reminder, link: link, input: input, calendar: calendar)
        }
    }

    private static func reconcile(
        task: TodoTask,
        reminder: RemindersSyncReminder,
        link: TaskReminderLink,
        input: RemindersSyncPlanInput,
        calendar: Calendar
    ) -> [RemindersSyncAction] {
        let taskChanged = changed(task.updatedAt, since: link.lastSyncedTaskUpdatedAt)
        let reminderChanged = changed(reminder.effectiveModifiedAt, since: link.lastSyncedReminderModifiedAt)
        let relinked = reminder.calendarItemIdentifier != link.calendarItemIdentifier

        enum Winner { case task, reminder }
        let winner: Winner?
        switch input.direction {
        case .twoWay:
            if taskChanged && reminderChanged {
                winner = task.updatedAt >= reminder.effectiveModifiedAt ? .task : .reminder
            } else if taskChanged {
                winner = .task
            } else if reminderChanged {
                winner = .reminder
            } else {
                winner = nil
            }
        case .importOnly:
            winner = reminderChanged ? .reminder : nil
        case .exportOnly:
            winner = taskChanged ? .task : nil
        }

        var actions: [RemindersSyncAction] = []
        switch winner {
        case .task?:
            actions = push(task: task, onto: reminder, mapping: input.mapping, calendar: calendar)
        case .reminder?:
            actions = pull(reminder: reminder, onto: task, mapping: input.mapping, calendar: calendar)
        case nil:
            break
        }
        if actions.isEmpty && (relinked || taskChanged || reminderChanged) {
            // Nothing to write, but record the new stamps / identifier so the
            // pair reads as settled next round.
            actions = [.link(taskId: task.id, calendarItemIdentifier: reminder.calendarItemIdentifier)]
        }
        return actions
    }

    /// Task wins: write its fields onto the reminder where they differ.
    private static func push(
        task: TodoTask,
        onto reminder: RemindersSyncReminder,
        mapping: RemindersListMapping,
        calendar: Calendar
    ) -> [RemindersSyncAction] {
        var actions: [RemindersSyncAction] = []
        let desired = RemindersFieldMapping.reminderFields(from: task, calendar: calendar)

        var differs = desired.title != reminder.title
            || desired.notes != reminder.notes
            || !RemindersFieldMapping.dueEqual(desired.due, reminder.due, calendar: calendar)
            || RemindersFieldMapping.scribePriority(fromReminderPriority: reminder.priority) != task.priority

        let taskRecurrence = RemindersFieldMapping.normalizedRecurrence(task.recurrenceRule)
        let includeRecurrence = taskRecurrence.supported && !reminder.hasUnsupportedRecurrence
        if includeRecurrence,
           taskRecurrence.rule != RemindersFieldMapping.normalizedRecurrence(reminder.recurrenceRule).rule {
            differs = true
        }

        var moveTo: String?
        if let target = mapping.listId(forProjectId: task.projectId), target != reminder.listId {
            moveTo = target
        }

        if differs || moveTo != nil {
            actions.append(.updateReminder(
                calendarItemIdentifier: reminder.calendarItemIdentifier,
                taskId: task.id,
                moveToListId: moveTo,
                fields: desired,
                includeRecurrence: includeRecurrence
            ))
        }

        let taskDone = RemindersFieldMapping.isDone(task)
        if taskDone != reminder.isCompleted {
            actions.append(.setReminderCompletion(
                calendarItemIdentifier: reminder.calendarItemIdentifier,
                taskId: task.id,
                isCompleted: taskDone,
                completionDate: taskDone ? (task.completedAt ?? task.cancelledAt) : nil
            ))
        }
        return actions
    }

    /// Reminder wins: write its fields onto the task where they differ.
    private static func pull(
        reminder: RemindersSyncReminder,
        onto task: TodoTask,
        mapping: RemindersListMapping,
        calendar: Calendar
    ) -> [RemindersSyncAction] {
        var actions: [RemindersSyncAction] = []
        let current = RemindersSyncTaskChanges(task: task)
        var desired = current

        let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { desired.title = reminder.title }
        desired.notes = reminder.notes
        let currentDue = RemindersFieldMapping.due(fromTaskDueAt: task.dueAt, calendar: calendar)
        if !RemindersFieldMapping.dueEqual(currentDue, reminder.due, calendar: calendar) {
            desired.dueAt = RemindersFieldMapping.taskDueAt(from: reminder.due, calendar: calendar)
        }
        // Keep the task's priority when it maps to the same bucket (EventKit
        // 3 and Scribe "high" are the same thing).
        let reminderPriority = RemindersFieldMapping.scribePriority(fromReminderPriority: reminder.priority)
        if reminderPriority != task.priority { desired.priority = reminderPriority }

        let taskRecurrence = RemindersFieldMapping.normalizedRecurrence(task.recurrenceRule)
        let reminderRecurrence = RemindersFieldMapping.normalizedRecurrence(reminder.recurrenceRule)
        if taskRecurrence.supported && reminderRecurrence.supported && !reminder.hasUnsupportedRecurrence,
           taskRecurrence.rule != reminderRecurrence.rule {
            desired.recurrenceRule = reminderRecurrence.rule
        }
        // Scribe requires a due date on recurring tasks.
        if desired.dueAt == nil { desired.recurrenceRule = nil }

        // Follow a list move only while the task lives in a mapped scope. A
        // task the user moved into an unmapped project keeps its reminder in
        // the old list (push never moves it), so that list says nothing about
        // where the task belongs — don't pull the task back out of its project.
        if mapping.listId(forProjectId: task.projectId) != nil,
           let target = mapping.projectTarget(forListId: reminder.listId) {
            desired.projectId = target.projectId
        }

        if desired != current {
            actions.append(.updateTask(
                taskId: task.id,
                calendarItemIdentifier: reminder.calendarItemIdentifier,
                changes: desired
            ))
        }

        if reminder.isCompleted != RemindersFieldMapping.isDone(task) {
            actions.append(.setTaskCompletion(
                taskId: task.id,
                calendarItemIdentifier: reminder.calendarItemIdentifier,
                isCompleted: reminder.isCompleted,
                completionDate: reminder.isCompleted ? reminder.completionDate : nil
            ))
        }
        return actions
    }

    private static func recreateReminder(for task: TodoTask, listId: String, calendar: Calendar) -> RemindersSyncAction {
        let done = RemindersFieldMapping.isDone(task)
        return .createReminder(
            taskId: task.id,
            listId: listId,
            fields: RemindersFieldMapping.reminderFields(from: task, calendar: calendar),
            isCompleted: done,
            completionDate: done ? (task.completedAt ?? task.cancelledAt) : nil
        )
    }

    private static func recreateTask(
        from reminder: RemindersSyncReminder,
        target: RemindersProjectTarget,
        calendar: Calendar
    ) -> RemindersSyncAction {
        .createTask(
            calendarItemIdentifier: reminder.calendarItemIdentifier,
            changes: RemindersFieldMapping.taskChanges(from: reminder, projectId: target.projectId, calendar: calendar),
            isCompleted: reminder.isCompleted
        )
    }

    // MARK: - Unlinked items (first contact)

    private static func planUnlinked(
        tasks: [TodoTask],
        reminders: [RemindersSyncReminder],
        input: RemindersSyncPlanInput,
        calendar: Calendar
    ) -> [RemindersSyncAction] {
        let mapping = input.mapping
        let direction = input.direction

        // Only open items in mapped scopes take part; finished history is
        // never bulk-copied across.
        let candidateTasks = tasks.filter { task in
            !RemindersFieldMapping.isDone(task)
                && !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && mapping.listId(forProjectId: task.projectId) != nil
        }
        let candidateReminders = reminders
            .filter { reminder in
                !reminder.isCompleted
                    && !reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && mapping.projectTarget(forListId: reminder.listId) != nil
            }
            .sorted { lhs, rhs in
                let l = lhs.creationDate ?? .distantPast
                let r = rhs.creationDate ?? .distantPast
                return l == r ? lhs.calendarItemIdentifier < rhs.calendarItemIdentifier : l < r
            }

        var remindersByKey: [String: [RemindersSyncReminder]] = [:]
        for reminder in candidateReminders {
            let key = RemindersFieldMapping.matchKey(title: reminder.title, due: reminder.due, calendar: calendar)
            remindersByKey[key, default: []].append(reminder)
        }

        var actions: [RemindersSyncAction] = []
        var matchedReminders = Set<String>()

        for task in candidateTasks {
            let due = RemindersFieldMapping.due(fromTaskDueAt: task.dueAt, calendar: calendar)
            let key = RemindersFieldMapping.matchKey(title: task.title, due: due, calendar: calendar)
            if var bucket = remindersByKey[key], !bucket.isEmpty {
                let reminder = bucket.removeFirst()
                remindersByKey[key] = bucket
                matchedReminders.insert(reminder.calendarItemIdentifier)
                actions.append(.link(taskId: task.id, calendarItemIdentifier: reminder.calendarItemIdentifier))
                actions += fillEmptyFields(task: task, reminder: reminder, direction: direction)
            } else if direction.writesReminders, let listId = mapping.listId(forProjectId: task.projectId) {
                actions.append(.createReminder(
                    taskId: task.id,
                    listId: listId,
                    fields: RemindersFieldMapping.reminderFields(from: task, calendar: calendar),
                    isCompleted: false,
                    completionDate: nil
                ))
            }
        }

        if direction.writesTasks {
            for reminder in candidateReminders where !matchedReminders.contains(reminder.calendarItemIdentifier) {
                guard let target = mapping.projectTarget(forListId: reminder.listId) else { continue }
                actions.append(.createTask(
                    calendarItemIdentifier: reminder.calendarItemIdentifier,
                    changes: RemindersFieldMapping.taskChanges(from: reminder, projectId: target.projectId, calendar: calendar),
                    isCompleted: false
                ))
            }
        }
        return actions
    }

    /// On first pairing, copy notes / priority only into a side where they're
    /// empty — never overwrite existing content.
    private static func fillEmptyFields(
        task: TodoTask,
        reminder: RemindersSyncReminder,
        direction: RemindersSyncDirection
    ) -> [RemindersSyncAction] {
        var actions: [RemindersSyncAction] = []

        if direction.writesTasks {
            var changes = RemindersSyncTaskChanges(task: task)
            if task.notes.isEmpty && !reminder.notes.isEmpty { changes.notes = reminder.notes }
            if task.priority == nil {
                changes.priority = RemindersFieldMapping.scribePriority(fromReminderPriority: reminder.priority)
            }
            if changes != RemindersSyncTaskChanges(task: task) {
                actions.append(.updateTask(
                    taskId: task.id,
                    calendarItemIdentifier: reminder.calendarItemIdentifier,
                    changes: changes
                ))
            }
        }

        if direction.writesReminders {
            var fields = RemindersFieldMapping.currentFields(of: reminder)
            if reminder.notes.isEmpty && !task.notes.isEmpty { fields.notes = task.notes }
            if reminder.priority == 0 { fields.priority = RemindersFieldMapping.reminderPriority(from: task.priority) }
            if fields != RemindersFieldMapping.currentFields(of: reminder) {
                actions.append(.updateReminder(
                    calendarItemIdentifier: reminder.calendarItemIdentifier,
                    taskId: task.id,
                    moveToListId: nil,
                    fields: fields,
                    includeRecurrence: false
                ))
            }
        }
        return actions
    }

    // MARK: - Helpers

    /// Any move of the stamp counts — backwards too: CloudKit task sync
    /// writes remote edits with their original (possibly older) `updatedAt`.
    private static func changed(_ stamp: Date, since recorded: Date?) -> Bool {
        guard let recorded else { return true }
        return abs(stamp.timeIntervalSince(recorded)) > changeTolerance
    }

    /// Holds back every delete on a side when that side's deletions look like
    /// a broken snapshot rather than user intent. Nothing is lost: the links
    /// stay, so the deletes are reconsidered next round.
    private static func applySafetyGuard(_ actions: [RemindersSyncAction], input: RemindersSyncPlanInput) -> RemindersSyncPlan {
        var taskDeletes: [String] = []
        var reminderDeletes: [String] = []
        for action in actions {
            switch action {
            case .deleteTask(let taskId, _):        taskDeletes.append(taskId)
            case .deleteReminder(let reminderId, _): reminderDeletes.append(reminderId)
            default: break
            }
        }
        let linkCount = input.links.count
        // An empty Reminders snapshot while pairs exist is never trusted.
        let holdTaskDeletes = !taskDeletes.isEmpty
            && (input.reminders.isEmpty
                || !input.reminderSnapshotIsComplete
                || exceedsDeleteSafetyLimit(deletes: taskDeletes.count, linkCount: linkCount))
        let holdReminderDeletes = !reminderDeletes.isEmpty
            && (input.tasks.isEmpty || exceedsDeleteSafetyLimit(deletes: reminderDeletes.count, linkCount: linkCount))

        var plan = RemindersSyncPlan()
        plan.actions = actions.filter { action in
            switch action {
            case .deleteTask:     return !holdTaskDeletes
            case .deleteReminder: return !holdReminderDeletes
            default:              return true
            }
        }
        if holdTaskDeletes { plan.suppressedTaskDeletes = taskDeletes }
        if holdReminderDeletes { plan.suppressedReminderDeletes = reminderDeletes }
        return plan
    }
}
