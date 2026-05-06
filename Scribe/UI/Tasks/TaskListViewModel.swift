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
    @Published private(set) var taskTags: [String: [String]] = [:]
    @Published var quickAddText: String = ""
    /// Free-text query for the search bar. When non-empty, `groups` is
    /// ignored and `searchResults` drives the detail pane instead.
    @Published var searchQuery: String = "" {
        didSet { runSearch() }
    }
    @Published private(set) var searchResults: [TodoTask] = []
    /// Currently focused row id; drives keyboard-shortcut targets (Space to
    /// toggle, Cmd-Backspace to delete).
    @Published var focusedTaskId: String?
    @Published private(set) var recentlyCompletedRecurring: Set<String> = []

    // MARK: - Properties

    private let store: TaskStore
    private let reminderScheduler: TaskReminderScheduling
    private var cancellable: AnyCancellable?
    private(set) var filter: TaskStore.Filter
    private var recurringClearTasks: [String: Task<Void, Never>] = [:]

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
        cancellable = store.observeTasks(filter: filter)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] tasks in
                    guard let self else { return }
                    self.groups = Self.bucket(tasks: tasks, calendar: .current, now: Date())
                    self.taskTags = (try? self.store.fetchTagsForTasks(tasks.map(\.id))) ?? [:]
                }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    func switchFilter(to newFilter: TaskStore.Filter) {
        guard newFilter != filter else { return }
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
        let parsed = QuickAddParser.parse(raw)
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
                projectId: projectId,
                priority: parsed.priority,
                dueAt: parsed.dueAt,
                tags: parsed.tags
            )
            quickAddText = ""
        } catch {
            Log.ui.error("TaskListViewModel.commitQuickAdd failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Row actions

    func toggleCompleted(_ task: TodoTask) {
        do {
            if task.isCompleted {
                try store.uncompleteTask(id: task.id)
                // Re-schedule any reminder the user already set on the task
                // (the helper short-circuits when remindAt is nil/past).
                if let refreshed = try store.fetchTask(id: task.id) {
                    Task { await reminderScheduler.schedule(refreshed) }
                }
            } else {
                try store.completeTask(id: task.id)
                if task.recurrenceRule != nil {
                    recentlyCompletedRecurring.insert(task.id)
                    recurringClearTasks[task.id]?.cancel()
                    recurringClearTasks[task.id] = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        self?.recentlyCompletedRecurring.remove(task.id)
                        self?.recurringClearTasks.removeValue(forKey: task.id)
                    }
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

    func delete(_ task: TodoTask) {
        do {
            try store.deleteTask(id: task.id)
            Task { await reminderScheduler.cancel(taskId: task.id) }
        } catch {
            Log.ui.error("TaskListViewModel.delete failed: \(error.localizedDescription, privacy: .public)")
        }
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
