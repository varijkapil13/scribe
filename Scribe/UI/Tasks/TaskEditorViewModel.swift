import Combine
import Foundation
import SwiftUI

/// Drives the slide-in editor sheet for a single task. Holds draft state so
/// the user can edit, then commit (`save`) or discard (`cancel`) without
/// touching the underlying row until they confirm.
@MainActor
final class TaskEditorViewModel: ObservableObject {

    // MARK: - Draft state

    @Published var title: String
    @Published var notes: String
    @Published var projectId: String?
    @Published var priority: TodoTask.Priority?
    @Published var dueAt: Date?
    @Published var remindAt: Date?
    @Published var tagsInput: String
    @Published private(set) var availableProjects: [Project] = []
    @Published private(set) var saveError: String?

    let originalTask: TodoTask

    // MARK: - Properties

    private let store: TaskStore

    // MARK: - Initializer

    init(task: TodoTask, store: TaskStore = TaskStore()) {
        self.originalTask = task
        self.store = store
        self.title = task.title
        self.notes = task.notes
        self.projectId = task.projectId
        self.priority = task.priority
        self.dueAt = task.dueAt
        self.remindAt = task.remindAt
        self.tagsInput = ""
        loadProjects()
        loadTags()
    }

    // MARK: - Loading

    private func loadProjects() {
        do {
            availableProjects = try store.fetchProjects()
        } catch {
            Log.ui.error("TaskEditorViewModel.loadProjects failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadTags() {
        do {
            let tags = try store.tags(for: originalTask.id)
            tagsInput = tags.joined(separator: ", ")
        } catch {
            Log.ui.error("TaskEditorViewModel.loadTags failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Actions

    /// Persists every editable field plus tags. Returns true on success so the
    /// caller can dismiss the sheet.
    @discardableResult
    func save() -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            saveError = "Title can't be empty."
            return false
        }
        do {
            var updated = originalTask
            updated.title = trimmedTitle
            updated.notes = notes
            updated.projectId = projectId
            updated.priority = priority
            updated.dueAt = dueAt
            updated.remindAt = remindAt
            try store.updateTask(updated)
            try store.setTags(parsedTags, for: updated.id)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            Log.ui.error("TaskEditorViewModel.save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func delete() {
        do {
            try store.deleteTask(id: originalTask.id)
        } catch {
            saveError = error.localizedDescription
            Log.ui.error("TaskEditorViewModel.delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Creates a sibling task with the same fields and tags but a new id.
    /// Returns the new task on success.
    @discardableResult
    func duplicate() -> TodoTask? {
        do {
            let copy = try store.createTask(
                title: title.isEmpty ? originalTask.title : title,
                notes: notes,
                projectId: projectId,
                priority: priority,
                dueAt: dueAt,
                remindAt: remindAt,
                recurrenceRule: originalTask.recurrenceRule,
                sourceSessionId: originalTask.sourceSessionId,
                sourceActionItemId: originalTask.sourceActionItemId,
                tags: parsedTags
            )
            return copy
        } catch {
            saveError = error.localizedDescription
            Log.ui.error("TaskEditorViewModel.duplicate failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Tag parsing

    /// Splits the freeform tag input into normalised tokens. Comma-separated;
    /// trim, lowercase, drop empties. The store re-normalises on insert so
    /// this is mostly cosmetic.
    var parsedTags: [String] {
        Self.parseTags(tagsInput)
    }

    nonisolated static func parseTags(_ input: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in input.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
