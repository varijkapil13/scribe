import AppIntents
import Foundation

/// A Scribe task as Shortcuts / Siri see it.
struct TaskEntity: AppEntity, Sendable {

    let id: String
    let title: String
    let dueAt: Date?
    /// `TodoTask.Priority` raw value ("High" / "Medium" / "Low"), nil = none.
    let priority: String?
    let isCompleted: Bool

    init(id: String, title: String, dueAt: Date?, priority: String?, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.priority = priority
        self.isCompleted = isCompleted
    }

    init(task: TodoTask) {
        self.init(
            id: task.id,
            title: ScribeIntentsText.displayTitle(task.title, fallback: "Untitled task"),
            dueAt: task.dueAt,
            priority: task.priority?.rawValue,
            isCompleted: task.isCompleted
        )
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Task")
    }

    static var defaultQuery: TaskEntityQuery { TaskEntityQuery() }

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let dueAt {
            parts.append("Due " + dueAt.formatted(date: .abbreviated, time: .omitted))
        }
        if let priority { parts.append(priority + " priority") }
        let subtitle: LocalizedStringResource? = parts.isEmpty ? nil : "\(parts.joined(separator: " · "))"
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle,
            image: DisplayRepresentation.Image(systemName: isCompleted ? "checkmark.circle" : "circle")
        )
    }
}

/// Resolves tasks by id, by text (full-text search over open tasks) and
/// suggests today's tasks, then the other open ones.
struct TaskEntityQuery: EntityStringQuery {

    init() {}

    func entities(for identifiers: [TaskEntity.ID]) async throws -> [TaskEntity] {
        try ScribeIntentsData.live.tasks(ids: identifiers).map(TaskEntity.init(task:))
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        try ScribeIntentsData.live.searchTasks(string).map(TaskEntity.init(task:))
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        try ScribeIntentsData.live.suggestedTasks().map(TaskEntity.init(task:))
    }
}

/// Task priority choice for "Create Task".
enum TaskPriorityAppEnum: String, AppEnum, CaseIterable, Sendable {
    case high
    case medium
    case low

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Priority")
    }

    static var caseDisplayRepresentations: [TaskPriorityAppEnum: DisplayRepresentation] {
        [
            .high: DisplayRepresentation(title: "High", image: DisplayRepresentation.Image(systemName: "exclamationmark.3")),
            .medium: DisplayRepresentation(title: "Medium", image: DisplayRepresentation.Image(systemName: "exclamationmark.2")),
            .low: DisplayRepresentation(title: "Low", image: DisplayRepresentation.Image(systemName: "exclamationmark")),
        ]
    }

    /// The stored task priority.
    var taskPriority: TodoTask.Priority {
        switch self {
        case .high:   return .high
        case .medium: return .medium
        case .low:    return .low
        }
    }
}
