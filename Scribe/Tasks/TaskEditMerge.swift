import Foundation

/// Field-level merge for a task editor that autosaves a whole row.
///
/// The editor keeps the row it loaded (`baseline`) and the user's working
/// copy (`edited`). Before writing, its edits are replayed onto the row as it
/// is stored now (`current`), so a change made elsewhere in the meantime —
/// the task completed from the list beside the editor, a recurring
/// completion advancing the due date, a snooze, an iCloud / Reminders sync
/// round — isn't overwritten by stale fields. Pure.
enum TaskEditMerge {

    /// `current` with every editor field that differs between `edited` and
    /// `baseline` copied from `edited`. Fields the editor doesn't write
    /// directly (project, heading, completion, sort order, timestamps…) always
    /// come from `current`.
    static func rebased(edited: TodoTask, baseline: TodoTask, onto current: TodoTask) -> TodoTask {
        var result = current
        func take<Value: Equatable>(_ keyPath: WritableKeyPath<TodoTask, Value>) {
            if edited[keyPath: keyPath] != baseline[keyPath: keyPath] {
                result[keyPath: keyPath] = edited[keyPath: keyPath]
            }
        }
        take(\.title)
        take(\.notes)
        take(\.priority)
        take(\.dueAt)
        take(\.remindAt)
        take(\.recurrenceRule)
        take(\.isPinned)
        take(\.startAt)
        take(\.scheduleBucket)
        take(\.estimatedMinutes)
        take(\.areaId)
        return result
    }
}
