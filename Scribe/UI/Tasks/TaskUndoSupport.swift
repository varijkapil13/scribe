import Foundation

/// Which persisted fields an undoable task action changed — and therefore which
/// fields undo/redo copy back from a snapshot. Restoring only these (instead
/// of the whole row) keeps unrelated edits made in between intact.
enum TaskUndoField: Hashable, Sendable {
    /// `completedAt` + `cancelledAt`, plus `dueAt` (a recurring task's
    /// completion advances its due date).
    case completion
    case dueDate
    case priority

    /// `current` with `fields` copied from `snapshot`. Pure.
    nonisolated static func applying(_ fields: Set<TaskUndoField>,
                                     from snapshot: TodoTask,
                                     to current: TodoTask) -> TodoTask {
        var result = current
        if fields.contains(.completion) {
            result.completedAt = snapshot.completedAt
            result.cancelledAt = snapshot.cancelledAt
            result.dueAt = snapshot.dueAt
        }
        if fields.contains(.dueDate) {
            result.dueAt = snapshot.dueAt
        }
        if fields.contains(.priority) {
            result.priority = snapshot.priority
        }
        return result
    }
}

/// A deleted task with what it needs to come back: tags and checklist.
struct DeletedTaskSnapshot {
    let task: TodoTask
    let tags: [String]
    let subtasks: [TaskSubtask]
}

/// Store-level undo/redo operations for tasks. Used by `TaskListViewModel`
/// through `UndoableActions`; they never register undo themselves.
enum TaskUndo {

    /// Copies `fields` from each snapshot onto the stored task (skipping tasks
    /// that no longer exist). Returns the tasks as stored afterwards.
    @discardableResult
    static func restore(_ snapshots: [TodoTask],
                        fields: Set<TaskUndoField>,
                        store: TaskStore) -> [TodoTask] {
        var restored: [TodoTask] = []
        for snapshot in snapshots {
            do {
                guard let current = try store.fetchTask(id: snapshot.id) else { continue }
                let updated = TaskUndoField.applying(fields, from: snapshot, to: current)
                try store.updateTask(updated)
                if let stored = try store.fetchTask(id: snapshot.id) { restored.append(stored) }
            } catch {
                Log.ui.error("TaskUndo.restore failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return restored
    }

    /// Captures what's needed to bring a task back after it is deleted.
    static func snapshotForDeletion(id: String, store: TaskStore) -> DeletedTaskSnapshot? {
        guard let task = try? store.fetchTask(id: id) else { return nil }
        let tags = (try? store.tags(for: id)) ?? []
        let subtasks = (try? store.subtasks(for: id)) ?? []
        return DeletedTaskSnapshot(task: task, tags: tags, subtasks: subtasks)
    }

    /// Re-creates a deleted task under its original id, with its tags and
    /// checklist. `updatedAt` is stamped fresh so iCloud sync treats the
    /// restore as newer than the delete it reverses. (Completion history of a
    /// recurring task is not restored.)
    @discardableResult
    static func restoreDeleted(_ snapshot: DeletedTaskSnapshot, store: TaskStore) -> TodoTask? {
        do {
            // Inserts the row verbatim and clears the delete tombstone…
            try store.upsertFromSync(snapshot.task)
            // …then bumps updatedAt past the tombstone's deletedAt.
            try store.updateTask(snapshot.task)
            try store.setTags(snapshot.tags, for: snapshot.task.id)
            for subtask in snapshot.subtasks.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let added = try store.addSubtask(to: snapshot.task.id, title: subtask.title)
                if subtask.isCompleted {
                    try store.setSubtaskCompleted(id: added.id, isCompleted: true)
                }
            }
            return try store.fetchTask(id: snapshot.task.id)
        } catch {
            Log.ui.error("TaskUndo.restoreDeleted failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
