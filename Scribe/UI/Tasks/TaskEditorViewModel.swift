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
    /// Legacy comma-separated tag entry, still used by the modal
    /// `TaskEditorView`. The inline `TaskDetailPanel` uses the structured
    /// `tags` array (token field) instead; `parsedTags` reconciles both.
    @Published var tagsInput: String
    /// Structured tag tokens edited via the inspector's chip/token field.
    /// Kept in sync with `tagsInput` so either entry path round-trips.
    @Published var tags: [String]
    @Published private(set) var availableProjects: [Project] = []
    @Published private(set) var saveError: String?
    /// Title of the meeting session this task originated from, when the task
    /// has a `sourceSessionId` AND that session still exists. Surfaced as a
    /// "From: <title>" link in the editor sheet. Nil when the task has no
    /// source session, or the source recording was since deleted — callers
    /// distinguish those two cases via `sourceSessionId`.
    @Published private(set) var sourceSessionTitle: String?
    /// Identifier of the meeting session this task was converted from, if any.
    /// Drives the navigable "From: <recording>" affordance: when this is set
    /// but `sourceSessionTitle` is nil, the source recording was deleted.
    var sourceSessionId: String? { originalTask.sourceSessionId }
    /// Bumps on every successful (debounced or flushed) save so the inspector
    /// can flash a brief "Saved" confirmation. Driven by `save()`.
    @Published private(set) var lastSavedAt: Date?
    /// All known tags across the store — feeds the token field's prefix
    /// autocomplete. Loaded once at init.
    @Published private(set) var allTags: [String] = []

    let originalTask: TodoTask

    // MARK: - Properties

    private let store: TaskStore
    private let transcriptStore: TranscriptStore
    private let reminderScheduler: TaskReminderScheduling
    private var autoSaveCancellable: AnyCancellable?

    // MARK: - Initializer

    init(task: TodoTask,
         store: TaskStore = TaskStore(),
         transcriptStore: TranscriptStore = TranscriptStore(),
         reminderScheduler: TaskReminderScheduling = TaskReminderScheduler.shared) {
        self.originalTask = task
        self.store = store
        self.transcriptStore = transcriptStore
        self.reminderScheduler = reminderScheduler
        self.title = task.title
        self.notes = task.notes
        self.projectId = task.projectId
        self.priority = task.priority
        self.dueAt = task.dueAt
        self.remindAt = task.remindAt
        self.tagsInput = ""
        self.tags = []
        loadProjects()
        loadTags()
        loadAllTags()
        loadSourceSessionTitle()
        setupAutoSave()
    }

    private func setupAutoSave() {
        // dropFirst() skips the initial value emitted when each @Published is set in init.
        let changes = Publishers.MergeMany([
            $title.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $notes.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $projectId.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $priority.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $dueAt.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $remindAt.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $tagsInput.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $tags.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        autoSaveCancellable = changes
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in _ = self?.save() }
    }

    /// Forces an immediate save, bypassing the 500ms debounce. Call this on
    /// inspector dismiss / Close so an in-flight edit is never lost (the old
    /// Escape-discard data-loss trap). Returns the result of `save()`.
    @discardableResult
    func flush() -> Bool {
        save()
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
            let loaded = try store.tags(for: originalTask.id)
            tags = loaded
            tagsInput = loaded.joined(separator: ", ")
        } catch {
            Log.ui.error("TaskEditorViewModel.loadTags failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAllTags() {
        do {
            allTags = try store.allTags()
        } catch {
            Log.ui.error("TaskEditorViewModel.loadAllTags failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Tag mutation (token field)

    /// Adds a normalised tag token (used by the inspector's token field). No-op
    /// on blank input or duplicates; keeps `tagsInput` in sync for the modal.
    func addTag(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        tagsInput = tags.joined(separator: ", ")
    }

    /// Removes a tag token by value.
    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        tagsInput = tags.joined(separator: ", ")
    }

    /// Tags in `allTags` matching the given prefix that aren't already applied.
    /// Drives the token field's autocomplete suggestions.
    func tagSuggestions(matching prefix: String) -> [String] {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return allTags.filter { $0.hasPrefix(needle) && !tags.contains($0) }
    }

    private func loadSourceSessionTitle() {
        guard let sessionId = originalTask.sourceSessionId else { return }
        sourceSessionTitle = (try? transcriptStore.fetchSession(id: sessionId))?.title
    }

    // MARK: - Actions

    /// Persists every editable field plus tags. Returns true on success so the
    /// caller can dismiss the sheet.
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
            // (Re-)schedule the reminder. The scheduler decides whether the
            // task is a candidate (no-op on past / cleared remindAt).
            Task { await reminderScheduler.schedule(updated) }
            saveError = nil
            lastSavedAt = Date()
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
            Task { await reminderScheduler.cancel(taskId: originalTask.id) }
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

    /// Resolves the effective tag set for persistence. The token field keeps
    /// `tags` and `tagsInput` in sync, so they normally agree. When they diverge
    /// the legacy comma-separated `tagsInput` (modal `TaskEditorView`) was edited
    /// directly — honour it. The store re-normalises on insert so this is mostly
    /// cosmetic.
    var parsedTags: [String] {
        let fromInput = Self.parseTags(tagsInput)
        if fromInput == tags { return tags }
        // The text field and the token array disagree: the modal editor edited
        // `tagsInput` independently. Prefer whichever was actually mutated by
        // taking `tagsInput` (the token field always mirrors into it).
        return fromInput
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
