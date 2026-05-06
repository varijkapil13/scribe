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
    @Published var quickAddText: String = ""

    // MARK: - Properties

    private let store: TaskStore
    private var cancellable: AnyCancellable?
    private(set) var filter: TaskStore.Filter

    // MARK: - Initializer

    init(filter: TaskStore.Filter, store: TaskStore = TaskStore()) {
        self.filter = filter
        self.store = store
    }

    // MARK: - Subscription lifecycle

    func start() {
        cancellable = store.observeTasks(filter: filter)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] tasks in
                    self?.groups = Self.bucket(tasks: tasks, calendar: .current, now: Date())
                }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    // MARK: - Quick add

    /// Creates an Inbox task from `quickAddText`. Always creates with no project/date regardless
    /// of the active filter — tasks added from Today/Upcoming will land in Inbox/No-date.
    /// Slice 8: upgrade to NL parsing so dates, tags, and priority are inferred from the text,
    /// and consider whether the active filter should seed defaults (e.g. today's date for Today filter).
    func commitQuickAdd() {
        let title = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try store.createTask(title: title)
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
            } else {
                try store.completeTask(id: task.id)
            }
        } catch {
            Log.ui.error("TaskListViewModel.toggleCompleted failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ task: TodoTask) {
        do {
            try store.deleteTask(id: task.id)
        } catch {
            Log.ui.error("TaskListViewModel.delete failed: \(error.localizedDescription, privacy: .public)")
        }
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
