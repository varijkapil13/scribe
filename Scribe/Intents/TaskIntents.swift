import AppIntents
import Foundation

/// Creates a task.
struct CreateTaskIntent: AppIntent {

    static var title: LocalizedStringResource { "Create Task" }

    @Parameter(title: "Title")
    var taskTitle: String

    @Parameter(title: "Due Date")
    var dueDate: Date?

    @Parameter(title: "Priority")
    var priority: TaskPriorityAppEnum?

    @Parameter(title: "Note")
    var taskNotes: String?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> & ProvidesDialog {
        let title = taskTitle
        let due = dueDate
        let taskPriority = priority?.taskPriority
        let notes = taskNotes ?? ""
        let entity = try await ScribeIntentsBridge.createTask(
            title: title,
            dueAt: due,
            priority: taskPriority,
            notes: notes
        )
        return .result(value: entity, dialog: "Added \(entity.title).")
    }
}

/// Marks a task done (recurring tasks advance to their next occurrence).
struct CompleteTaskIntent: AppIntent {

    static var title: LocalizedStringResource { "Complete Task" }

    @Parameter(title: "Task")
    var task: TaskEntity

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> & ProvidesDialog {
        let taskId = task.id
        let entity = try await ScribeIntentsBridge.completeTask(id: taskId)
        return .result(value: entity, dialog: "Completed \(entity.title).")
    }
}

/// Lists open tasks due today or overdue.
struct ListTodayTasksIntent: AppIntent {

    static var title: LocalizedStringResource { "List Today's Tasks" }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[TaskEntity]> & ProvidesDialog {
        let tasks = try ScribeIntentsData.live.todayTasks().map(TaskEntity.init(task:))
        let dialog: IntentDialog
        switch tasks.count {
        case 0:  dialog = "You have no tasks for today."
        case 1:  dialog = "You have 1 task for today: \(tasks[0].title)."
        default: dialog = "You have \(tasks.count) tasks for today."
        }
        return .result(value: tasks, dialog: dialog)
    }
}
