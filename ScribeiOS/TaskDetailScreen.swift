import Combine
import Foundation
import SwiftUI

/// Baseline task editor: title, notes, due date, priority, and a complete
/// toggle in a `Form`. Loads the task via `TaskStore.fetchTask(id:)` and
/// autosaves on change (debounced) and on disappear — mirroring
/// `NoteEditorModel`'s proven autosave/flush pattern.
struct TaskDetailScreen: View {
    let taskId: String

    @StateObject private var model: TaskEditorModel

    init(taskId: String) {
        self.taskId = taskId
        _model = StateObject(wrappedValue: TaskEditorModel(taskId: taskId))
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $model.title)
                TextEditor(text: $model.notes)
                    .frame(minHeight: 96)
            }

            Section("Due date") {
                Toggle("Has due date", isOn: $model.hasDueDate)
                if model.hasDueDate {
                    DatePicker("Due", selection: $model.dueDate)
                }
            }

            Section("Priority") {
                Picker("Priority", selection: $model.priority) {
                    Text("None").tag(TodoTask.Priority?.none)
                    ForEach(TodoTask.Priority.allCases, id: \.self) { priority in
                        Text(priority.rawValue).tag(TodoTask.Priority?.some(priority))
                    }
                }
            }

            Section {
                Toggle("Completed", isOn: $model.isCompleted)
            }
        }
        .navigationTitle(model.title.isEmpty ? "Task" : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.title) { model.markDirty() }
        .onChange(of: model.notes) { model.markDirty() }
        .onChange(of: model.hasDueDate) { model.markDirty() }
        .onChange(of: model.dueDate) { model.markDirty() }
        .onChange(of: model.priority) { model.markDirty() }
        .onChange(of: model.isCompleted) { model.setCompleted(model.isCompleted) }
        .onDisappear { model.flush() }
    }
}

// MARK: - View model

@MainActor
final class TaskEditorModel: ObservableObject {
    @Published var title: String = ""
    @Published var notes: String = ""
    @Published var hasDueDate: Bool = false
    @Published var dueDate: Date = Date()
    @Published var priority: TodoTask.Priority?
    @Published var isCompleted: Bool = false

    private let taskId: String
    private let store: TaskStore
    private var task: TodoTask?
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    init(taskId: String, store: TaskStore = .shared) {
        self.taskId = taskId
        self.store = store
        load()
    }

    private func load() {
        guard let task = try? store.fetchTask(id: taskId) else { return }
        self.task = task
        self.title = task.title
        self.notes = task.notes
        self.hasDueDate = task.dueAt != nil
        self.dueDate = task.dueAt ?? Date()
        self.priority = task.priority
        self.isCompleted = task.isCompleted
    }

    func markDirty() {
        dirty = true
        // Debounced autosave; flush() also covers teardown.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard dirty, var task else { return }
        task.title = title
        task.notes = notes
        task.dueAt = hasDueDate ? dueDate : nil
        task.priority = priority
        try? store.updateTask(task)
        self.task = task
        dirty = false
    }

    /// Completion goes through the store's dedicated complete/uncomplete calls
    /// (which write a history row), so it's applied immediately rather than via
    /// the debounced `updateTask` path.
    func setCompleted(_ completed: Bool) {
        guard let task, task.isCompleted != completed else { return }
        if completed {
            try? store.completeTask(id: task.id)
        } else {
            try? store.uncompleteTask(id: task.id)
        }
        self.task = try? store.fetchTask(id: task.id)
    }
}
