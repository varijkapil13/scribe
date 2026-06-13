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
        case tomorrow
        case thisWeek
        case later
        case noDate
        case completed

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .thisWeek: return "This week"
            case .later: return "Later"
            case .noDate: return "No date"
            case .completed: return "Completed"
            }
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
        let bucketed = Self.bucket(tasks: effective, calendar: .current, now: Date())
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
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .created:
                return a.createdAt < b.createdAt
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

        do {
            _ = try store.createTask(
                title: parsed.title,
                notes: notes,
                projectId: projectId,
                priority: parsed.priority,
                dueAt: parsed.dueAt ?? quickAddDueDate ?? defaultDueDate(),
                tags: parsed.tags
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
    private func defaultDueDate() -> Date {
        if case .dueOn(let date) = filter {
            return Calendar.current.startOfDay(for: date)
        }
        return Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Row actions

    func toggleCompleted(_ task: TodoTask) {
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
        do {
            try store.deleteTask(id: task.id)
            Task { await reminderScheduler.cancel(taskId: task.id) }
        } catch {
            Log.ui.error("TaskListViewModel.delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Inline edits

    /// Inline due-date reschedule. Used by the in-row date popover, the
    /// "Reschedule to >" context menu, and drag-to-bucket drops.
    func setDueDate(_ date: Date?, for task: TodoTask) {
        var updated = task
        updated.dueAt = date
        commitInline(updated)
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
        var updated = task
        updated.priority = priority
        commitInline(updated)
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
        runBatch { _ = try store.completeTasks(ids: $0) }
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
        runBatch { _ = try store.deleteTasks(ids: $0) }
        for id in ids {
            Task { await reminderScheduler.cancel(taskId: id) }
        }
    }

    func batchMove(toProject id: String?)         { runBatch { try store.moveTasks(ids: $0, toProject: id) } }
    func batchReschedule(to date: Date?)          { runBatch { try store.rescheduleTasks(ids: $0, to: date) } }
    func batchPriority(_ p: TodoTask.Priority?)   { runBatch { try store.setPriority(p, forTasks: $0) } }

    private func commitInline(_ task: TodoTask) {
        do {
            try store.updateTask(task)
            if let refreshed = try store.fetchTask(id: task.id) {
                Task { await reminderScheduler.schedule(refreshed) }
            }
        } catch {
            Log.ui.error("TaskListViewModel.commitInline failed: \(error.localizedDescription, privacy: .public)")
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
        } catch {
            Log.ui.error("TaskListViewModel.loadProjects failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func project(id: String?) -> Project? {
        guard let id else { return nil }
        return availableProjects.first { $0.id == id }
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

    /// Splits a task list into ordered buckets for the grouped UI. Pure
    /// function so it stays trivially testable.
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
        var completed: [TodoTask] = []

        for task in tasks {
            if task.isCompleted {
                completed.append(task)
                continue
            }
            guard let due = task.dueAt else {
                noDate.append(task)
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
        if !tomorrow.isEmpty  { out.append((.tomorrow, tomorrow)) }
        if !thisWeek.isEmpty  { out.append((.thisWeek, thisWeek)) }
        if !later.isEmpty     { out.append((.later, later)) }
        if !noDate.isEmpty    { out.append((.noDate, noDate)) }
        if !completed.isEmpty { out.append((.completed, completed)) }
        return out
    }
}
