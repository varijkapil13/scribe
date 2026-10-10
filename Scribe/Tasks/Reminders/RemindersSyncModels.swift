import Foundation

// Plain value types for the Apple Reminders sync. Nothing here imports
// EventKit: the macOS adapter (`RemindersEventStore`) converts EKReminder into
// `RemindersSyncReminder` snapshots, and `RemindersSyncPlanner` works purely on
// these values plus `TodoTask` rows and `TaskReminderLink`s, so the whole
// decision logic is unit-testable. Portable — also compiled into the iOS target.

// MARK: - Direction

/// Which way changes flow between Scribe tasks and Apple Reminders.
enum RemindersSyncDirection: String, CaseIterable, Identifiable, Sendable {
    /// Changes flow both ways; conflicts resolve last-writer-wins.
    case twoWay
    /// Reminders → Scribe only. Scribe never writes to Reminders.
    case importOnly
    /// Scribe → Reminders only. The sync never writes to Scribe tasks.
    case exportOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoWay:     return "Two-way"
        case .importOnly: return "Import from Reminders only"
        case .exportOnly: return "Export to Reminders only"
        }
    }

    /// Whether the sync may create/update/delete reminders.
    var writesReminders: Bool { self != .importOnly }
    /// Whether the sync may create/update/delete Scribe tasks.
    var writesTasks: Bool { self != .exportOnly }
}

// MARK: - Snapshots

/// A due date as Reminders models it: a calendar day ("date-only", stored as
/// local midnight) or a specific moment ("date-time").
struct RemindersSyncDue: Equatable, Sendable {
    var date: Date
    var hasTime: Bool

    init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }
}

/// One Reminders list (an `EKCalendar` of type reminder).
struct RemindersListInfo: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Value snapshot of one `EKReminder`.
struct RemindersSyncReminder: Equatable, Sendable {
    /// `calendarItemIdentifier`.
    var calendarItemIdentifier: String
    /// `calendarItemExternalIdentifier` (nil/empty when unknown).
    var externalIdentifier: String?
    /// The list (`EKCalendar.calendarIdentifier`) the reminder lives in.
    var listId: String
    var title: String
    /// Notes ("" when the reminder has none).
    var notes: String
    var due: RemindersSyncDue?
    /// EventKit priority: 0 = none, 1–4 high, 5 medium, 6–9 low.
    var priority: Int
    var isCompleted: Bool
    var completionDate: Date?
    /// RRULE-flavoured rule Scribe understands, or nil (no recurrence, or one
    /// too complex to map — see `hasUnsupportedRecurrence`).
    var recurrenceRule: String?
    /// The reminder repeats in a way Scribe can't represent (end date, yearly,
    /// several rules…). Recurrence is then left untouched on both sides.
    var hasUnsupportedRecurrence: Bool
    var lastModifiedAt: Date?
    var creationDate: Date?

    init(
        calendarItemIdentifier: String,
        externalIdentifier: String? = nil,
        listId: String,
        title: String,
        notes: String = "",
        due: RemindersSyncDue? = nil,
        priority: Int = 0,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        recurrenceRule: String? = nil,
        hasUnsupportedRecurrence: Bool = false,
        lastModifiedAt: Date? = nil,
        creationDate: Date? = nil
    ) {
        self.calendarItemIdentifier = calendarItemIdentifier
        self.externalIdentifier = externalIdentifier
        self.listId = listId
        self.title = title
        self.notes = notes
        self.due = due
        self.priority = priority
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.recurrenceRule = recurrenceRule
        self.hasUnsupportedRecurrence = hasUnsupportedRecurrence
        self.lastModifiedAt = lastModifiedAt
        self.creationDate = creationDate
    }

    /// The best "last changed" stamp available (modification, else creation).
    var effectiveModifiedAt: Date {
        lastModifiedAt ?? creationDate ?? .distantPast
    }
}

// MARK: - Plan payloads

/// The reminder-side field values to write (title, notes, due, priority,
/// recurrence). Completion travels separately.
struct RemindersSyncFields: Equatable, Sendable {
    var title: String
    var notes: String
    var due: RemindersSyncDue?
    /// EventKit priority (0, 1, 5 or 9 when produced from a Scribe task).
    var priority: Int
    /// Simple RRULE, or nil for "does not repeat".
    var recurrenceRule: String?

    init(title: String, notes: String, due: RemindersSyncDue?, priority: Int, recurrenceRule: String?) {
        self.title = title
        self.notes = notes
        self.due = due
        self.priority = priority
        self.recurrenceRule = recurrenceRule
    }
}

/// The task-side field values to write. Applied onto a freshly fetched task so
/// fields the sync doesn't own (tags, pin, reminders, sort order…) survive.
struct RemindersSyncTaskChanges: Equatable {
    var title: String
    var notes: String
    var dueAt: Date?
    var priority: TodoTask.Priority?
    var recurrenceRule: String?
    var projectId: String?

    init(
        title: String,
        notes: String,
        dueAt: Date?,
        priority: TodoTask.Priority?,
        recurrenceRule: String?,
        projectId: String?
    ) {
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.priority = priority
        self.recurrenceRule = recurrenceRule
        self.projectId = projectId
    }

    /// The fields of `task` as they stand.
    init(task: TodoTask) {
        self.init(
            title: task.title,
            notes: task.notes,
            dueAt: task.dueAt,
            priority: task.priority,
            recurrenceRule: task.recurrenceRule,
            projectId: task.projectId
        )
    }

    /// `task` with these fields applied (everything else untouched).
    func applied(to task: TodoTask) -> TodoTask {
        var copy = task
        copy.title = title
        copy.notes = notes
        copy.dueAt = dueAt
        copy.priority = priority
        copy.recurrenceRule = recurrenceRule
        copy.projectId = projectId
        return copy
    }
}

/// One step of a sync round. Every case names the task/reminder pair it
/// concerns so the adapter can refresh (or drop) that pair's link afterwards.
enum RemindersSyncAction: Equatable {
    /// Export a task as a new reminder in `listId`.
    case createReminder(taskId: String, listId: String, fields: RemindersSyncFields, isCompleted: Bool, completionDate: Date?)
    /// Overwrite the reminder's fields (completion excluded). `moveToListId`
    /// is non-nil when the reminder should move lists. When
    /// `includeRecurrence` is false, the reminder's recurrence is left alone.
    case updateReminder(calendarItemIdentifier: String, taskId: String, moveToListId: String?, fields: RemindersSyncFields, includeRecurrence: Bool)
    /// Mark the reminder complete / incomplete.
    case setReminderCompletion(calendarItemIdentifier: String, taskId: String, isCompleted: Bool, completionDate: Date?)
    /// Delete a reminder whose linked task was deleted in Scribe.
    case deleteReminder(calendarItemIdentifier: String, taskId: String)
    /// Import a reminder as a new Scribe task.
    case createTask(calendarItemIdentifier: String, changes: RemindersSyncTaskChanges, isCompleted: Bool)
    /// Overwrite the task's synced fields (completion excluded).
    case updateTask(taskId: String, calendarItemIdentifier: String, changes: RemindersSyncTaskChanges)
    /// Complete / reopen a task (reopening also clears "Won't do").
    case setTaskCompletion(taskId: String, calendarItemIdentifier: String, isCompleted: Bool, completionDate: Date?)
    /// Delete a task whose linked reminder was deleted in Reminders.
    case deleteTask(taskId: String, calendarItemIdentifier: String)
    /// Record (or refresh) the pairing without changing either side.
    case link(taskId: String, calendarItemIdentifier: String)
    /// Forget the pairing; neither side is touched.
    case unlink(taskId: String)
}

/// The output of `RemindersSyncPlanner.plan`.
struct RemindersSyncPlan: Equatable {
    var actions: [RemindersSyncAction] = []
    /// Task ids whose deletion the safety guard held back (see
    /// `RemindersSyncPlanner.exceedsDeleteSafetyLimit`).
    var suppressedTaskDeletes: [String] = []
    /// Reminder ids whose deletion the safety guard held back.
    var suppressedReminderDeletes: [String] = []

    /// True when the round changes nothing on either side (link-only
    /// bookkeeping aside).
    var changesNothing: Bool {
        actions.allSatisfy { action in
            switch action {
            case .link, .unlink: return true
            default:             return false
            }
        }
    }
}

// MARK: - List ↔ project mapping

/// Where a reminder in some list belongs on the Scribe side.
enum RemindersProjectTarget: Equatable {
    case inbox
    case project(String)

    var projectId: String? {
        switch self {
        case .inbox:              return nil
        case .project(let id):    return id
        }
    }
}

/// Resolved list ↔ project mapping: one Reminders list for the Scribe Inbox
/// (tasks without a project) plus optional one-to-one project ↔ list pairs.
/// Only tasks/reminders covered by the mapping are newly imported/exported.
struct RemindersListMapping: Equatable {
    var inboxListId: String?
    private(set) var projectToList: [String: String]
    private(set) var listToProject: [String: String]

    init(inboxListId: String?, projectToList: [String: String] = [:]) {
        self.inboxListId = inboxListId
        var forward: [String: String] = [:]
        var reverse: [String: String] = [:]
        // Deterministic one-to-one: iterate sorted so duplicates resolve the
        // same way every time; the inbox list is never also a project list.
        for (projectId, listId) in projectToList.sorted(by: { $0.key < $1.key }) {
            guard listId != inboxListId, reverse[listId] == nil else { continue }
            forward[projectId] = listId
            reverse[listId] = projectId
        }
        self.projectToList = forward
        self.listToProject = reverse
    }

    /// The list a task with `projectId` (nil = Inbox) syncs to, or nil when
    /// that project isn't mapped.
    func listId(forProjectId projectId: String?) -> String? {
        guard let projectId else { return inboxListId }
        return projectToList[projectId]
    }

    /// Where a reminder in `listId` belongs, or nil when the list isn't mapped.
    func projectTarget(forListId listId: String) -> RemindersProjectTarget? {
        if let inboxListId, listId == inboxListId { return .inbox }
        if let projectId = listToProject[listId] { return .project(projectId) }
        return nil
    }

    /// Builds the mapping from the user's settings. With `mapProjectsByName`,
    /// each project pairs with the list whose title matches its name (trimmed,
    /// case- and diacritic-insensitive); first project (by sort order) wins a
    /// contested list, and the Inbox list is never claimed by a project.
    static func resolve(
        projects: [Project],
        lists: [RemindersListInfo],
        inboxListId: String?,
        mapProjectsByName: Bool
    ) -> RemindersListMapping {
        let validInbox = inboxListId.flatMap { id in lists.contains { $0.id == id } ? id : nil }
        guard mapProjectsByName else {
            return RemindersListMapping(inboxListId: validInbox)
        }
        var listsByName: [String: [RemindersListInfo]] = [:]
        for list in lists where list.id != validInbox {
            listsByName[normalizedName(list.title), default: []].append(list)
        }
        var used = Set<String>()
        var pairs: [String: String] = [:]
        let ordered = projects.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder
        }
        for project in ordered {
            let key = normalizedName(project.name)
            guard !key.isEmpty,
                  let list = listsByName[key]?.first(where: { !used.contains($0.id) }) else { continue }
            used.insert(list.id)
            pairs[project.id] = list.id
        }
        return RemindersListMapping(inboxListId: validInbox, projectToList: pairs)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }
}
