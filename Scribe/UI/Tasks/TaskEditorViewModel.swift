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
    /// Defer / start date (v20).
    @Published var startAt: Date?
    /// Things-style when-bucket (v20).
    @Published var scheduleBucket: TaskScheduleBucket
    /// Duration estimate in minutes (v20); nil = none.
    @Published var estimatedMinutes: Int?
    /// Area for a task without a project (v20). Ignored (cleared on save)
    /// while `projectId` is set — the project's area applies instead.
    @Published var areaId: String?
    /// Heading inside the selected project (v20).
    @Published var headingId: String?
    @Published private(set) var availableAreas: [TaskArea] = []
    /// Headings of the currently selected project.
    @Published private(set) var availableHeadings: [ProjectHeading] = []
    /// Legacy comma-separated tag entry, still used by the modal
    /// `TaskEditorView`. The inline `TaskDetailPanel` uses the structured
    /// `tags` array (token field) instead; `parsedTags` reconciles both.
    @Published var tagsInput: String
    /// Structured tag tokens edited via the inspector's chip/token field.
    /// Kept in sync with `tagsInput` so either entry path round-trips.
    @Published var tags: [String]
    @Published private(set) var availableProjects: [Project] = []
    /// A *recoverable persistence failure* (disk/db write failed). Per the
    /// one-feedback-language convention (`FeedbackPolicy`), the view routes this
    /// to the unified banner rather than showing it inline.
    @Published private(set) var saveError: String?
    /// *Field-level validation* tied to the title control (e.g. "Title can't be
    /// empty"). Stays inline next to the field — never a substitute for
    /// surfacing an actual failure (see `FeedbackPolicy`).
    @Published private(set) var validationError: String?
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
        self.startAt = task.startAt
        self.scheduleBucket = task.scheduleBucket
        self.estimatedMinutes = task.estimatedMinutes
        self.areaId = task.areaId
        self.headingId = task.headingId
        self.tagsInput = ""
        self.tags = []
        loadProjects()
        loadAreas()
        loadHeadings(for: task.projectId)
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
            $startAt.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $scheduleBucket.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $estimatedMinutes.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $areaId.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $headingId.dropFirst().map { _ in () }.eraseToAnyPublisher(),
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

    private func loadAreas() {
        do {
            availableAreas = try store.fetchAreas()
        } catch {
            Log.ui.error("TaskEditorViewModel.loadAreas failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadHeadings(for projectId: String?) {
        guard let projectId else {
            availableHeadings = []
            return
        }
        do {
            availableHeadings = try store.headings(in: projectId)
        } catch {
            Log.ui.error("TaskEditorViewModel.loadHeadings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Changes the project from the inspector picker. A heading belongs to
    /// one project, so it's cleared; the heading list reloads for the new
    /// project.
    func selectProject(_ newProjectId: String?) {
        guard newProjectId != projectId else { return }
        projectId = newProjectId
        headingId = nil
        loadHeadings(for: newProjectId)
    }

    /// Area shown for the task: the project's when it has one, else its own.
    var effectiveAreaId: String? {
        if let projectId {
            return availableProjects.first(where: { $0.id == projectId })?.areaId
        }
        return areaId
    }

    /// Sets the when-bucket. Someday parks the task, so it drops any start
    /// date (a parked task isn't "deferred until" a day).
    func setScheduleBucket(_ bucket: TaskScheduleBucket) {
        scheduleBucket = bucket
        if bucket == .someday { startAt = nil }
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
            // Field validation → inline, tied to the title control.
            validationError = "Title can't be empty."
            return false
        }
        validationError = nil
        do {
            var updated = originalTask
            updated.title = trimmedTitle
            updated.notes = notes
            updated.projectId = projectId
            updated.priority = priority
            updated.dueAt = dueAt
            updated.remindAt = remindAt
            updated.startAt = startAt
            updated.scheduleBucket = scheduleBucket
            updated.estimatedMinutes = estimatedMinutes.map { max(0, $0) }
            // Planning links stay consistent: a task in a project uses the
            // project's area, and its heading must belong to that project.
            updated.areaId = projectId == nil ? areaId : nil
            updated.headingId = availableHeadings.contains(where: { $0.id == headingId && $0.projectId == projectId })
                ? headingId : nil
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
                tags: parsedTags,
                startAt: startAt,
                scheduleBucket: scheduleBucket,
                estimatedMinutes: estimatedMinutes,
                areaId: areaId,
                headingId: headingId
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
