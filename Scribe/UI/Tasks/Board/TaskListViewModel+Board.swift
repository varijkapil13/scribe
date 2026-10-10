import Combine
import Foundation

// MARK: - Board actions

extension TaskListViewModel {

    /// Every task the list currently shows, in display order (the board's
    /// "active" input). Includes settle snapshots of just-completed tasks.
    var boardActiveTasks: [TodoTask] {
        groups.flatMap(\.tasks)
    }

    /// Applies a card dropped on a board column: updates the grouping's field
    /// (status / project / priority), re-arms the task's reminder, and
    /// registers Edit › Undo. Returns whether anything changed.
    @discardableResult
    func moveOnBoard(
        _ task: TodoTask,
        to key: TaskBoardColumnKey,
        grouping: TaskBoardGrouping,
        calendar: Calendar,
        now: Date
    ) -> Bool {
        let before = (try? store.fetchTask(id: task.id)) ?? task
        let outcome = TaskBoardMove.outcome(dropping: before, into: key, calendar: calendar, now: now)
        do {
            switch outcome {
            case .unchanged:
                return false
            case .update(let updated):
                try store.updateTask(updated)
            case .complete:
                try store.completeTask(id: before.id, at: now)
            case .moveToProject(let projectId):
                try store.moveTask(id: before.id, toProject: projectId)
            }
        } catch {
            Log.ui.error("TaskListViewModel.moveOnBoard failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard let after = try? store.fetchTask(id: before.id) else { return true }
        Self.refreshBoardReminders(for: after, scheduler: reminderScheduler)
        registerBoardUndo(grouping.undoActionName, before: before, after: after, grouping: grouping)
        return true
    }

    /// Undo restores the grouping's fields from `before`; redo re-applies
    /// `after`'s. Both write the store directly (never through code that
    /// registers undo itself).
    private func registerBoardUndo(_ actionName: String,
                                   before: TodoTask,
                                   after: TodoTask,
                                   grouping: TaskBoardGrouping) {
        guard let undoManager else { return }
        let store = self.store
        let scheduler = reminderScheduler
        UndoableActions.register(
            on: undoManager,
            actionName: actionName,
            undo: {
                TaskListViewModel.applyBoardSnapshot(before, grouping: grouping, store: store, scheduler: scheduler)
            },
            redo: {
                TaskListViewModel.applyBoardSnapshot(after, grouping: grouping, store: store, scheduler: scheduler)
            }
        )
    }

    /// Copies `grouping`'s fields from `snapshot` onto the stored row (skips a
    /// task that no longer exists).
    static func applyBoardSnapshot(_ snapshot: TodoTask,
                                   grouping: TaskBoardGrouping,
                                   store: TaskStore,
                                   scheduler: TaskReminderScheduling) {
        do {
            guard let current = try store.fetchTask(id: snapshot.id) else { return }
            let restored = TaskBoardMove.restoring(grouping, from: snapshot, to: current)
            guard restored != current else { return }
            try store.updateTask(restored)
            if let stored = try store.fetchTask(id: snapshot.id) {
                refreshBoardReminders(for: stored, scheduler: scheduler)
            }
        } catch {
            Log.ui.error("Board undo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func refreshBoardReminders(for task: TodoTask, scheduler: TaskReminderScheduling) {
        if task.isCompleted || task.isCancelled {
            let id = task.id
            Task { await scheduler.cancel(taskId: id) }
        } else {
            Task { await scheduler.schedule(task) }
        }
    }
}

// MARK: - Done column feed

/// Observes finished (completed / cancelled) tasks for the board's Done
/// column — active task lists never include them. Started only while the
/// board shows the Status grouping.
@MainActor
final class TaskBoardDoneFeed: ObservableObject {

    /// Newest-finished first, capped (the Done column is a recent-history
    /// strip, not the whole archive).
    @Published private(set) var finished: [TodoTask] = []
    @Published private(set) var tagsByTask: [String: [String]] = [:]

    nonisolated static let limit = 300

    private let store: TaskStore
    private var cancellable: AnyCancellable?

    init(store: TaskStore) {
        self.store = store
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = store.observeTasks(filter: .completed)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] tasks in
                    guard let self else { return }
                    let newest = tasks.sorted { a, b in
                        let fa = a.completedAt ?? a.cancelledAt ?? .distantPast
                        let fb = b.completedAt ?? b.cancelledAt ?? .distantPast
                        return fa > fb
                    }
                    let capped = Array(newest.prefix(Self.limit))
                    self.finished = capped
                    self.tagsByTask = (try? self.store.fetchTagsForTasks(capped.map(\.id))) ?? [:]
                }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}

// MARK: - Per-filter preferences

/// UserDefaults-backed List/Board choice and board grouping, per task list.
enum TaskBoardPreferences {

    static func layoutMode(forFilterKey key: String) -> TaskListLayoutMode {
        let raw = UserDefaults.standard.string(forKey: "tasks.layout.\(key)") ?? ""
        return TaskListLayoutMode(rawValue: raw) ?? .list
    }

    static func setLayoutMode(_ mode: TaskListLayoutMode, forFilterKey key: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: "tasks.layout.\(key)")
    }

    static func grouping(forFilterKey key: String) -> TaskBoardGrouping {
        let raw = UserDefaults.standard.string(forKey: "tasks.boardGrouping.\(key)") ?? ""
        return TaskBoardGrouping(rawValue: raw) ?? .status
    }

    static func setGrouping(_ grouping: TaskBoardGrouping, forFilterKey key: String) {
        UserDefaults.standard.set(grouping.rawValue, forKey: "tasks.boardGrouping.\(key)")
    }
}
