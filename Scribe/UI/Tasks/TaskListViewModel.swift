import Combine
import Foundation
import SwiftUI

/// Drives the task list detail pane. Subscribes to `TaskStore.observeTasks`
/// for the current `TaskStore.Filter` so SwiftUI re-renders whenever the
/// underlying tasks/projects/tags tables change.
@MainActor
final class TaskListViewModel: ObservableObject {

    // MARK: - Date buckets

    /// Grouping used in the detail pane. Order matters — sections are rendered
    /// top-to-bottom in the order declared here.
    enum Bucket: Hashable {
        case overdue
        case today
        /// Today's "This Evening" section (Things-style evening plan).
        case evening
        case tomorrow
        case thisWeek
        case later
        case noDate
        /// Undated tasks parked in Someday.
        case someday
        /// A project heading section (project lists with headings only).
        case heading(ProjectHeading)
        case completed

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .today: return "Today"
            case .evening: return "This Evening"
            case .tomorrow: return "Tomorrow"
            case .thisWeek: return "This week"
            case .later: return "Later"
            case .noDate: return "No date"
            case .someday: return "Someday"
            case .heading(let heading): return heading.title.isEmpty ? "Untitled heading" : heading.title
            case .completed: return "Completed"
            }
        }

        /// The heading this section represents, if any.
        var heading: ProjectHeading? {
            if case .heading(let heading) = self { return heading }
            return nil
        }
    }

    // MARK: - Published state

    @Published private(set) var groups: [(bucket: Bucket, tasks: [TodoTask])] = []
    /// Subtask "n/m" progress per visible task id, for the list-row chip.
    @Published private(set) var subtaskProgress: [String: SubtaskProgress] = [:]
    /// Multi-select mode + the set of selected task ids (TickTick batch ops).
    @Published var isSelecting = false
    @Published var selection: Set<String> = []

    /// Active within-bucket sort (pinned always float first). `.smart` keeps the
    /// SQL order. Set by the view from its persisted per-filter preference.
    @Published var sortMode: TaskSort = .smart {
        didSet { if oldValue != sortMode { regroup() } }
    }

    /// Sort options offered in the list's Sort menu (TickTick parity).
    enum TaskSort: String, CaseIterable, Identifiable, Sendable {
        case smart    = "Smart"
        case dueDate  = "Due date"
        case priority = "Priority"
        case title    = "Title"
        case created  = "Date added"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .smart:    return "sparkles"
            case .dueDate:  return "calendar"
            case .priority: return "flag"
            case .title:    return "textformat"
            case .created:  return "clock"
            }
        }
    }
    @Published private(set) var taskTags: [String: [String]] = [:]
    @Published var quickAddText: String = ""
    /// Date selected via the calendar icon in the quick-add bar. Used as a
    /// fallback when the NLP parser finds no date phrase in `quickAddText`.
    @Published var quickAddDueDate: Date?
    /// Free-text query for the search bar. When non-empty, `groups` is
    /// ignored and `searchResults` drives the detail pane instead.
    @Published var searchQuery: String = "" {
        didSet { runSearch() }
    }
    @Published private(set) var searchResults: [TodoTask] = []
    /// Currently focused row id; drives keyboard-shortcut targets (Space to
    /// toggle, Cmd-Backspace to delete) and the keyboard-focus ring.
    @Published var focusedTaskId: String?
    /// Recurring tasks recently completed — kept struck-through in place ~1.5s
    /// before re-bucketing (their due date also advances).
    @Published private(set) var recentlyCompletedRecurring: Set<String> = []
    /// Any task (recurring or one-off) freshly toggled complete that should
    /// linger in its current bucket ~0.4s so the completion animation reads
    /// before the row jumps to "Completed".
    @Published private(set) var settlingTasks: Set<String> = []

    // MARK: - Properties

    private let store: TaskStore
    private let reminderScheduler: TaskReminderScheduling
    private var cancellable: AnyCancellable?
    private var headingsCancellable: AnyCancellable?
    /// Headings of the project being shown (`.project` filter only), in order.
    @Published private(set) var headings: [ProjectHeading] = []
    private(set) var filter: TaskStore.Filter
    private var recurringClearTasks: [String: Task<Void, Never>] = [:]
    private var settleClearTasks: [String: Task<Void, Never>] = [:]
    /// The most recent task list received from the store, retained so the
    /// settle-hold can suppress re-bucketing without re-querying.
    private var latestTasks: [TodoTask] = []
    /// Pre-toggle snapshots for settling tasks. While a task settles we render
    /// its snapshot (so it stays in its original bucket) instead of the freshly
    /// completed/rescheduled row the store now reports.
    private var settlingSnapshots: [String: TodoTask] = [:]

    // MARK: - Initializer

    init(filter: TaskStore.Filter,
         store: TaskStore = TaskStore(),
         reminderScheduler: TaskReminderScheduling = TaskReminderScheduler.shared) {
        self.filter = filter
        self.store = store
        self.reminderScheduler = reminderScheduler
    }

    // MARK: - Subscription lifecycle

    func start() {
        loadProjects()
        if case .project(let projectId) = filter {
            headingsCancellable = store.observeHeadings(projectId: projectId)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { [weak self] headings in
                        guard let self else { return }
                        self.headings = headings
                        self.regroup()
                    }
                )
        } else {
            headingsCancellable = nil
            headings = []
        }
        cancellable = store.observeTasks(filter: filter)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] tasks in
                    guard let self else { return }
                    self.latestTasks = tasks
                    self.taskTags = (try? self.store.fetchTagsForTasks(tasks.map(\.id))) ?? [:]
                    self.regroup()
                }
            )
    }

    /// Recomputes `groups` from `latestTasks`, substituting pre-toggle
    /// snapshots for any settling task so it lingers in its original bucket
    /// until the settle-hold elapses.
    private func regroup() {
        var effective = latestTasks
        if !settlingSnapshots.isEmpty {
            for (index, task) in effective.enumerated() {
                if let snapshot = settlingSnapshots[task.id] {
                    effective[index] = snapshot
                }
            }
            // A settling task that left the current filter's result set (e.g.
            // moved out of "Today") still needs to render — re-insert its
            // snapshot so it doesn't vanish mid-animation.
            let present = Set(effective.map(\.id))
            for (id, snapshot) in settlingSnapshots where !present.contains(id) {
                effective.append(snapshot)
            }
        }
        let bucketed = Self.bucket(tasks: effective, headings: headings, calendar: .current, now: Date())
        groups = bucketed.map { (bucket: $0.bucket, tasks: sorted($0.tasks)) }
        reloadSubtaskProgress()
    }

    /// Re-sorts a bucket's tasks by the active `sortMode`, keeping pinned
    /// tasks first. `.smart` preserves the SQL order untouched.
    private func sorted(_ tasks: [TodoTask]) -> [TodoTask] {
        guard sortMode != .smart else { return tasks }
        return tasks.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch sortMode {
            case .smart:
                return false
            case .dueDate:
                switch (a.dueAt, b.dueAt) {
                case let (x?, y?): return x != y ? x < y : a.sortOrder < b.sortOrder
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.sortOrder < b.sortOrder
                }
            case .priority:
                let ra = Self.priorityRank(a.priority), rb = Self.priorityRank(b.priority)
                return ra != rb ? ra < rb : a.sortOrder < b.sortOrder
            case .title:
                // Tiebreak equal titles by sortOrder so rows don't shuffle
                // unpredictably across re-sorts (the sort isn't stable).
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                return cmp == .orderedSame ? a.sortOrder < b.sortOrder : cmp == .orderedAscending
            case .created:
                return a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.sortOrder < b.sortOrder
            }
        }
    }

    private static func priorityRank(_ p: TodoTask.Priority?) -> Int {
        switch p {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        case nil:     return 3
        }
    }

    /// Batch-loads the "n/m" chip progress for the fetched task set (covers
    /// both grouped + search rows). Refreshes on each task change / filter
    /// switch — the inspector shows live checklist state regardless.
    private func reloadSubtaskProgress() {
        subtaskProgress = (try? store.subtaskProgress(for: latestTasks.map(\.id))) ?? [:]
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        headingsCancellable?.cancel()
        headingsCancellable = nil
    }

    func switchFilter(to newFilter: TaskStore.Filter) {
        guard newFilter != filter else { return }
        // Drop any in-flight settle-holds so they don't bleed into the new filter.
        settleClearTasks.values.forEach { $0.cancel() }
        settleClearTasks.removeAll()
        recurringClearTasks.values.forEach { $0.cancel() }
        recurringClearTasks.removeAll()
        settlingSnapshots.removeAll()
        settlingTasks.removeAll()
        recentlyCompletedRecurring.removeAll()
        filter = newFilter
        stop()
        start()
    }

    // MARK: - Quick add

    /// Parses `quickAddText` for inline metadata (`#tag`, `+project`,
    /// `!priority`, date phrases) and creates the task. Project hints are
    /// resolved against the existing project list — unknown names fall back
    /// to Inbox so the task is never silently dropped.
    func commitQuickAdd() {
        let raw = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // First line = title (with NLP tokens), remaining lines = notes.
        let lineBreak = raw.firstIndex(of: "\n")
        let titleRaw = lineBreak.map { String(raw[raw.startIndex..<$0]) } ?? raw
        let notes    = lineBreak.map { String(raw[raw.index(after: $0)...]).trimmingCharacters(in: .newlines) } ?? ""

        let parsed = QuickAddParser.parse(titleRaw)
        guard !parsed.title.isEmpty else { return }

        var projectId: String? = nil
        if let name = parsed.projectName {
            do {
                projectId = try store.fetchProjects()
                    .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            } catch {
                Log.ui.error("TaskListViewModel.commitQuickAdd fetchProjects failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Lists that imply a container file the new task there unless the
        // user typed an explicit +Project.
        var areaId: String? = nil
        if projectId == nil, parsed.projectName == nil {
            switch filter {
            case .project(let id): projectId = id
            case .area(let id):    areaId = id
            default:               break
            }
        }
        let isSomedayList = filter == TaskStore.Filter.someday
        let bucket: TaskScheduleBucket = parsed.scheduleBucket ?? (isSomedayList ? .someday : .anytime)

        do {
            _ = try store.createTask(
                title: parsed.title,
                notes: notes,
                projectId: projectId,
                priority: parsed.priority,
                dueAt: parsed.dueAt ?? quickAddDueDate ?? Self.defaultQuickAddDueDate(
                    filter: filter,
                    bucket: bucket,
                    startAt: parsed.startAt,
                    calendar: .current,
                    now: Date()
                ),
                recurrenceRule: parsed.recurrenceRule,
                tags: parsed.tags,
                startAt: parsed.startAt,
                scheduleBucket: bucket,
                estimatedMinutes: parsed.estimatedMinutes,
                areaId: areaId
            )
            quickAddText = ""
            quickAddDueDate = nil
        } catch {
            Log.ui.error("TaskListViewModel.commitQuickAdd failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Default due date for newly quick-added tasks when the user didn't
    /// type a date phrase and didn't pick one from the calendar popover.
    /// On the `.dueOn(date)` filter we honour the viewed date so tasks
    /// added from "yesterday" or "tomorrow" land in that same rail.
    ///
    /// Returns nil (no due date) when the task is planned another way — a
    /// Someday / This-Evening bucket or a start date — or when added from a
    /// container list (project / area / Someday), so it isn't silently made
    /// due today.
    nonisolated static func defaultQuickAddDueDate(
        filter: TaskStore.Filter,
        bucket: TaskScheduleBucket,
        startAt: Date?,
        calendar: Calendar,
        now: Date
    ) -> Date? {
        if bucket == .someday || bucket == .evening || startAt != nil { return nil }
        switch filter {
        case .dueOn(let date):
            return calendar.startOfDay(for: date)
        case .project, .area, .someday:
            return nil
        default:
            return calendar.startOfDay(for: now)
        }
    }

    // MARK: - Row actions

    func toggleCompleted(_ task: TodoTask) {
        let before = (try? store.fetchTask(id: task.id)) ?? task
        do {
            if task.isCompleted {
                // Cancel any in-flight settle for this row before un-completing.
                clearSettle(task.id)
                try store.uncompleteTask(id: task.id)
                // Re-schedule any reminder the user already set on the task
                // (the helper short-circuits when remindAt is nil/past).
                if let refreshed = try store.fetchTask(id: task.id) {
                    Task { await reminderScheduler.schedule(refreshed) }
                }
            } else {
                // Snapshot the pre-completion row so it lingers in its current
                // bucket (struck-through) for the settle-hold before jumping to
                // "Completed" / re-scheduling. Generalised from the old
                // recurring-only hold to every task.
                settlingSnapshots[task.id] = task
                settlingTasks.insert(task.id)
                if task.recurrenceRule != nil {
                    recentlyCompletedRecurring.insert(task.id)
                }

                try store.completeTask(id: task.id)

                // One-off tasks settle quickly (~0.4s); recurring tasks linger
                // longer (1.5s) since their due date also advances.
                let holdSeconds = task.recurrenceRule != nil ? 1.5 : 0.4
                settleClearTasks[task.id]?.cancel()
                settleClearTasks[task.id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(holdSeconds))
                    guard !Task.isCancelled else { return }
                    self?.clearSettle(task.id)
                }

                // Recurring tasks now have a fresh `dueAt` — re-arm the
                // reminder against the next occurrence; one-off tasks just
                // get their pending reminder cleared.
                if let refreshed = try store.fetchTask(id: task.id) {
                    if refreshed.isCompleted {
                        Task { await reminderScheduler.cancel(taskId: task.id) }
                    } else {
                        Task { await reminderScheduler.schedule(refreshed) }
                    }
                }
            }
            registerFieldUndo(task.isCompleted ? "Mark Task Incomplete" : "Complete Task",
                              before: [before], fields: [.completion])
        } catch {
            Log.ui.error("TaskListViewModel.toggleCompleted failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the settle-hold for a task and re-buckets it into its final
    /// position. Idempotent.
    private func clearSettle(_ id: String) {
        settleClearTasks[id]?.cancel()
        settleClearTasks.removeValue(forKey: id)
        let hadSnapshot = settlingSnapshots.removeValue(forKey: id) != nil
        let wasSettling = settlingTasks.remove(id) != nil
        recentlyCompletedRecurring.remove(id)
        if hadSnapshot || wasSettling { regroup() }
    }

    func delete(_ task: TodoTask) {
        let snapshot = TaskUndo.snapshotForDeletion(id: task.id, store: store)
        do {
            try store.deleteTask(id: task.id)
            Task { await reminderScheduler.cancel(taskId: task.id) }
            registerDeleteUndo(snapshot.map { [$0] } ?? [])
        } catch {
            Log.ui.error("TaskListViewModel.delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Inline edits

    /// Inline due-date reschedule. Used by the in-row date popover, the
    /// "Reschedule to >" context menu, and drag-to-bucket drops.
    func setDueDate(_ date: Date?, for task: TodoTask) {
        let before = (try? store.fetchTask(id: task.id)) ?? task
        var updated = task
        updated.dueAt = date
        if commitInline(updated) {
            registerFieldUndo("Change Due Date", before: [before], fields: [.dueDate])
        }
    }

    /// Cycles priority None → High → Medium → Low → None (click-to-cycle on the
    /// priority dot). Also reachable as discrete "Priority >" menu items.
    func cyclePriority(for task: TodoTask) {
        let next: TodoTask.Priority?
        switch task.priority {
        case .none:   next = .high
        case .high:   next = .medium
        case .medium: next = .low
        case .low:    next = nil
        }
        setPriority(next, for: task)
    }

    func setPriority(_ priority: TodoTask.Priority?, for task: TodoTask) {
        let before = (try? store.fetchTask(id: task.id)) ?? task
        var updated = task
        updated.priority = priority
        if commitInline(updated) {
            registerFieldUndo("Change Priority", before: [before], fields: [.priority])
        }
    }

    /// Inline title rename (double-click to edit in place).
    func setTitle(_ title: String, for task: TodoTask) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        var updated = task
        updated.title = trimmed
        commitInline(updated)
    }

    /// Moves a task to a project (or Inbox when nil) via the chip menu / drag.
    func moveToProject(_ projectId: String?, for task: TodoTask) {
        do {
            try store.moveTask(id: task.id, toProject: projectId)
        } catch {
            Log.ui.error("TaskListViewModel.moveToProject failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancels ("Won't do") or restores a task.
    func cancelTask(_ task: TodoTask) {
        do {
            try store.cancelTask(id: task.id)
            // A cancelled task shouldn't still fire its reminder.
            Task { await reminderScheduler.cancel(taskId: task.id) }
        }
        catch { Log.ui.error("TaskListViewModel.cancelTask failed: \(error.localizedDescription, privacy: .public)") }
    }

    func uncancelTask(_ task: TodoTask) {
        do {
            try store.uncancelTask(id: task.id)
            // Restoring re-arms the reminder if it still has a future remindAt.
            if let refreshed = try store.fetchTask(id: task.id) {
                Task { await reminderScheduler.schedule(refreshed) }
            }
        }
        catch { Log.ui.error("TaskListViewModel.uncancelTask failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Toggles the pin that floats a task to the top of its bucket.
    func togglePin(_ task: TodoTask) {
        do { try store.setPinned(!task.isPinned, for: task.id) }
        catch { Log.ui.error("TaskListViewModel.togglePin failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Multi-select batch (TickTick parity)

    func enterSelectMode() { isSelecting = true }
    func exitSelectMode() { isSelecting = false; selection.removeAll() }

    func toggleSelected(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func runBatch(_ work: ([String]) throws -> Void) {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        do {
            try work(ids)
            AccessibilityNotification.Announcement("\(ids.count) tasks updated").post()
        } catch {
            Log.ui.error("TaskListViewModel batch op failed: \(error.localizedDescription, privacy: .public)")
        }
        exitSelectMode()
    }

    func batchComplete() {
        // Capture ids before runBatch clears the selection, so reminders can
        // be re-armed (recurring) or cancelled (completed) like the single-task
        // toggle path does — otherwise batch-completed tasks keep firing.
        let ids = Array(selection)
        let before = (try? store.tasks(forIDs: ids)) ?? []
        runBatch { _ = try store.completeTasks(ids: $0) }
        registerFieldUndo(ids.count == 1 ? "Complete Task" : "Complete Tasks",
                          before: before, fields: [.completion])
        for id in ids {
            Task { @MainActor in
                guard let refreshed = try? store.fetchTask(id: id) else { return }
                if refreshed.isCompleted {
                    await reminderScheduler.cancel(taskId: id)
                } else {
                    await reminderScheduler.schedule(refreshed)
                }
            }
        }
    }

    func batchDelete() {
        // Capture ids before the selection is cleared so we can cancel each
        // task's pending reminder — the single-task delete already does this.
        let ids = Array(selection)
        let snapshots = ids.compactMap { TaskUndo.snapshotForDeletion(id: $0, store: store) }
        runBatch { _ = try store.deleteTasks(ids: $0) }
        for id in ids {
            Task { await reminderScheduler.cancel(taskId: id) }
        }
        let remaining = (try? store.tasks(forIDs: ids)) ?? []
        if remaining.isEmpty { registerDeleteUndo(snapshots) }
    }

    func batchMove(toProject id: String?)         { runBatch { try store.moveTasks(ids: $0, toProject: id) } }

    func batchReschedule(to date: Date?) {
        let before = (try? store.tasks(forIDs: Array(selection))) ?? []
        runBatch { try store.rescheduleTasks(ids: $0, to: date) }
        registerFieldUndo("Change Due Date", before: before, fields: [.dueDate])
    }

    func batchPriority(_ p: TodoTask.Priority?) {
        let before = (try? store.tasks(forIDs: Array(selection))) ?? []
        runBatch { try store.setPriority(p, forTasks: $0) }
        registerFieldUndo("Change Priority", before: before, fields: [.priority])
    }

    @discardableResult
    private func commitInline(_ task: TodoTask) -> Bool {
        do {
            try store.updateTask(task)
            if let refreshed = try store.fetchTask(id: task.id) {
                Task { await reminderScheduler.schedule(refreshed) }
            }
            return true
        } catch {
            Log.ui.error("TaskListViewModel.commitInline failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Undo (Edit › Undo / Redo)

    /// The window's undo manager, handed in by `TaskListView`. Completion,
    /// delete, due-date and priority changes register their inverse with it.
    weak var undoManager: UndoManager?

    /// Registers undo/redo for an action that changed `fields` on the tasks
    /// whose pre-action state is `before`. No-op when nothing changed.
    private func registerFieldUndo(_ actionName: String,
                                   before: [TodoTask],
                                   fields: Set<TaskUndoField>) {
        guard let undoManager, !before.isEmpty else { return }
        let after = (try? store.tasks(forIDs: before.map(\.id))) ?? []
        let changed = before.contains { old in
            guard let new = after.first(where: { $0.id == old.id }) else { return false }
            return TaskUndoField.applying(fields, from: old, to: new) != new
        }
        guard changed else { return }
        let store = self.store
        let scheduler = reminderScheduler
        UndoableActions.register(
            on: undoManager,
            actionName: actionName,
            undo: { [weak self] in
                let restored = TaskUndo.restore(before, fields: fields, store: store)
                self?.didApplyUndo(to: restored)
                TaskListViewModel.refreshReminders(for: restored, scheduler: scheduler)
            },
            redo: { [weak self] in
                let restored = TaskUndo.restore(after, fields: fields, store: store)
                self?.didApplyUndo(to: restored)
                TaskListViewModel.refreshReminders(for: restored, scheduler: scheduler)
            }
        )
    }

    /// Registers undo (restore) / redo (delete again) for deleted tasks.
    private func registerDeleteUndo(_ snapshots: [DeletedTaskSnapshot]) {
        guard let undoManager, !snapshots.isEmpty else { return }
        let store = self.store
        let scheduler = reminderScheduler
        let ids = snapshots.map(\.task.id)
        UndoableActions.register(
            on: undoManager,
            actionName: snapshots.count == 1 ? "Delete Task" : "Delete Tasks",
            undo: {
                let restored = snapshots.compactMap { TaskUndo.restoreDeleted($0, store: store) }
                TaskListViewModel.refreshReminders(for: restored, scheduler: scheduler)
            },
            redo: {
                do {
                    _ = try store.deleteTasks(ids: ids)
                } catch {
                    Log.ui.error("TaskListViewModel redo delete failed: \(error.localizedDescription, privacy: .public)")
                }
                for id in ids {
                    Task { await scheduler.cancel(taskId: id) }
                }
            }
        )
    }

    /// Ends any completion settle-hold on tasks an undo/redo just changed so
    /// they re-bucket immediately.
    private func didApplyUndo(to tasks: [TodoTask]) {
        for task in tasks { clearSettle(task.id) }
    }

    /// Re-arms (or cancels) reminders to match tasks an undo/redo changed.
    private static func refreshReminders(for tasks: [TodoTask], scheduler: TaskReminderScheduling) {
        for task in tasks {
            if task.isCompleted || task.isCancelled {
                let id = task.id
                Task { await scheduler.cancel(taskId: id) }
            } else {
                Task { await scheduler.schedule(task) }
            }
        }
    }

    /// Persists an in-bucket reorder. The visible bucket the drag happened in is
    /// reordered as one project scope; ids outside that scope are untouched.
    func reorder(_ orderedIds: [String], inProject projectId: String?) {
        do {
            try store.reorderTasks(orderedIds, in: projectId)
        } catch {
            Log.ui.error("TaskListViewModel.reorder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves the project a project name belongs to (case-insensitive).
    func projectId(named name: String) -> String? {
        availableProjects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    // MARK: - Projects (for inline move + chip)

    @Published private(set) var availableProjects: [Project] = []

    func loadProjects() {
        do {
            availableProjects = try store.fetchProjects()
            availableAreas = try store.fetchAreas()
        } catch {
            Log.ui.error("TaskListViewModel.loadProjects failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func project(id: String?) -> Project? {
        guard let id else { return nil }
        return availableProjects.first { $0.id == id }
    }

    // MARK: - Planning (areas, headings, when-buckets)

    @Published private(set) var availableAreas: [TaskArea] = []

    func area(id: String?) -> TaskArea? {
        guard let id else { return nil }
        return availableAreas.first { $0.id == id }
    }

    /// Sets a task's when-bucket. Choosing This Evening on an undated task
    /// keeps it undated (it shows in Today's evening section); choosing
    /// Someday clears any start date so the task is parked, not deferred.
    func setScheduleBucket(_ bucket: TaskScheduleBucket, for task: TodoTask) {
        var updated = task
        updated.scheduleBucket = bucket
        if bucket == .someday { updated.startAt = nil }
        commitInline(updated)
    }

    /// Plans a task for this evening: evening bucket, and if it's dated on
    /// another day, moved to today (time-of-day kept).
    func planForEvening(_ task: TodoTask) {
        var updated = task
        updated.scheduleBucket = .evening
        updated.startAt = nil
        let cal = Calendar.current
        if let due = task.dueAt, !cal.isDateInToday(due) {
            let time = cal.dateComponents([.hour, .minute], from: due)
            updated.dueAt = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                     second: 0, of: Date()) ?? cal.startOfDay(for: Date())
        }
        commitInline(updated)
    }

    /// Reschedules and resets the when-bucket in one write (drag onto a date
    /// section takes a task out of an Evening / Someday plan).
    func setDueDate(_ date: Date?, bucket: TaskScheduleBucket, for task: TodoTask) {
        var updated = task
        updated.dueAt = date
        updated.scheduleBucket = bucket
        commitInline(updated)
    }

    /// Files a task under one of the current project's headings (nil = none).
    func setHeading(_ headingId: String?, for task: TodoTask) {
        do { try store.setHeading(headingId, forTask: task.id) }
        catch { Log.ui.error("TaskListViewModel.setHeading failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Adds a heading at the bottom of the current project (`.project` only).
    func addHeading(title: String) {
        guard case .project(let projectId) = filter else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try store.createHeading(in: projectId, title: trimmed) }
        catch { Log.ui.error("TaskListViewModel.addHeading failed: \(error.localizedDescription, privacy: .public)") }
    }

    func renameHeading(_ heading: ProjectHeading, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != heading.title else { return }
        do { try store.renameHeading(id: heading.id, title: trimmed) }
        catch { Log.ui.error("TaskListViewModel.renameHeading failed: \(error.localizedDescription, privacy: .public)") }
    }

    func deleteHeading(_ heading: ProjectHeading) {
        do { try store.deleteHeading(id: heading.id) }
        catch { Log.ui.error("TaskListViewModel.deleteHeading failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Moves a heading one slot up (`delta` −1) or down (+1).
    func moveHeading(_ heading: ProjectHeading, by delta: Int) {
        let ids = Self.movingHeading(heading.id, by: delta, in: headings.map(\.id))
        guard ids != headings.map(\.id) else { return }
        do { try store.reorderHeadings(ids, in: heading.projectId) }
        catch { Log.ui.error("TaskListViewModel.moveHeading failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Pure helper: `ids` with `id` shifted by `delta` positions (clamped).
    nonisolated static func movingHeading(_ id: String, by delta: Int, in ids: [String]) -> [String] {
        guard let index = ids.firstIndex(of: id) else { return ids }
        let target = min(max(index + delta, 0), ids.count - 1)
        guard target != index else { return ids }
        var out = ids
        out.remove(at: index)
        out.insert(id, at: target)
        return out
    }

    // MARK: - Keyboard navigation

    /// All currently visible task ids in render order — the flat list the
    /// keyboard focus (arrows / j-k) traverses. Mirrors the order the view
    /// renders buckets, honouring search mode.
    func flatVisibleTaskIds(visibleGroups: [(bucket: Bucket, tasks: [TodoTask])]) -> [String] {
        if isSearching { return searchResults.map(\.id) }
        return visibleGroups.flatMap { $0.tasks.map(\.id) }
    }

    /// Moves keyboard focus by `delta` rows through the flattened visible list.
    /// Wraps at the ends and seeds focus on the first row when nothing is
    /// focused yet.
    func moveFocus(by delta: Int, in ids: [String]) {
        guard !ids.isEmpty else { focusedTaskId = nil; return }
        guard let current = focusedTaskId, let idx = ids.firstIndex(of: current) else {
            focusedTaskId = delta >= 0 ? ids.first : ids.last
            return
        }
        let next = (idx + delta + ids.count) % ids.count
        focusedTaskId = ids[next]
    }

    /// Looks up a task by id across visible groups, search results, and the
    /// retained latest set.
    func task(id: String) -> TodoTask? {
        for group in groups {
            if let task = group.tasks.first(where: { $0.id == id }) { return task }
        }
        if let task = searchResults.first(where: { $0.id == id }) { return task }
        return latestTasks.first(where: { $0.id == id })
    }

    // MARK: - Search

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runSearch() {
        guard isSearching else {
            searchResults = []
            return
        }
        do {
            searchResults = try store.searchTasks(query: searchQuery)
        } catch {
            Log.ui.error("TaskListViewModel.runSearch failed: \(error.localizedDescription, privacy: .public)")
            searchResults = []
        }
    }

    func tags(for taskId: String) -> [String] {
        taskTags[taskId] ?? []
    }

    // MARK: - Bucketing

    /// Like `bucket(tasks:calendar:now:)`, then files active tasks under their
    /// project headings: un-headed date sections first, then one section per
    /// heading in order (empty ones included, so they accept drops), then
    /// Completed. With no headings this is exactly `bucket(tasks:…)`.
    nonisolated static func bucket(
        tasks: [TodoTask],
        headings: [ProjectHeading],
        calendar: Calendar,
        now: Date
    ) -> [(bucket: Bucket, tasks: [TodoTask])] {
        guard !headings.isEmpty else { return bucket(tasks: tasks, calendar: calendar, now: now) }
        let headingIds = Set(headings.map(\.id))
        var headed: [String: [TodoTask]] = [:]
        var rest: [TodoTask] = []
        for task in tasks {
            if !task.isCompleted, let headingId = task.headingId, headingIds.contains(headingId) {
                headed[headingId, default: []].append(task)
            } else {
                rest.append(task)
            }
        }
        let base = bucket(tasks: rest, calendar: calendar, now: now)
        var out = base.filter { $0.bucket != .completed }
        for heading in headings {
            out.append((.heading(heading), headed[heading.id] ?? []))
        }
        out.append(contentsOf: base.filter { $0.bucket == .completed })
        return out
    }

    /// Splits a task list into ordered buckets for the grouped UI. Pure
    /// function so it stays trivially testable.
    ///
    /// Planning-aware: overdue always leads; an evening-planned task that's
    /// due today (or undated) lands in This Evening; an explicit Today plan
    /// lands in Today; an undated Someday task in Someday; and an undated task
    /// deferred to a future start date is placed by that start date.
    nonisolated static func bucket(tasks: [TodoTask], calendar: Calendar, now: Date) -> [(bucket: Bucket, tasks: [TodoTask])] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday)!
        let startOfNext7 = calendar.date(byAdding: .day, value: 7, to: startOfToday)!

        var overdue: [TodoTask] = []
        var today: [TodoTask] = []
        var tomorrow: [TodoTask] = []
        var thisWeek: [TodoTask] = []
        var later: [TodoTask] = []
        var noDate: [TodoTask] = []
        var evening: [TodoTask] = []
        var someday: [TodoTask] = []
        var completed: [TodoTask] = []

        for task in tasks {
            if task.isCompleted {
                completed.append(task)
                continue
            }
            if let due = task.dueAt, due < startOfToday {
                overdue.append(task)
                continue
            }
            if task.scheduleBucket == .evening, (task.dueAt ?? startOfToday) < startOfTomorrow {
                evening.append(task)
                continue
            }
            if task.scheduleBucket == .today {
                today.append(task)
                continue
            }
            // Undated + deferred: place by the start date.
            var effectiveDate = task.dueAt
            if effectiveDate == nil, let start = task.startAt, start >= startOfTomorrow {
                effectiveDate = start
            }
            guard let due = effectiveDate else {
                if task.scheduleBucket == .someday {
                    someday.append(task)
                } else {
                    noDate.append(task)
                }
                continue
            }
            if due < startOfToday {
                overdue.append(task)
            } else if due < startOfTomorrow {
                today.append(task)
            } else if due < startOfDayAfterTomorrow {
                tomorrow.append(task)
            } else if due < startOfNext7 {
                thisWeek.append(task)
            } else {
                later.append(task)
            }
        }

        var out: [(bucket: Bucket, tasks: [TodoTask])] = []
        if !overdue.isEmpty   { out.append((.overdue, overdue)) }
        if !today.isEmpty     { out.append((.today, today)) }
        if !evening.isEmpty   { out.append((.evening, evening)) }
        if !tomorrow.isEmpty  { out.append((.tomorrow, tomorrow)) }
        if !thisWeek.isEmpty  { out.append((.thisWeek, thisWeek)) }
        if !later.isEmpty     { out.append((.later, later)) }
        if !noDate.isEmpty    { out.append((.noDate, noDate)) }
        if !someday.isEmpty   { out.append((.someday, someday)) }
        if !completed.isEmpty { out.append((.completed, completed)) }
        return out
    }
}
