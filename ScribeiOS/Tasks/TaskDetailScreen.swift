import Combine
import Foundation
import SwiftUI

/// Full task editor: title, notes, when-bucket, start / due dates (with or
/// without a time), duration, reminder, repeat (incl. until / count / after
/// completion), priority, project / heading / area, tags, checklist, pin,
/// completion, won't-do and delete. Plain field edits autosave (debounced,
/// flushed on disappear); filing and completion write immediately.
struct TaskDetailScreen: View {
    let taskId: String
    /// Called after the task is deleted (iPad clears the detail column).
    var onDeleted: (() -> Void)?

    @StateObject private var model: TaskDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var newSubtask = ""
    @State private var newTag = ""
    @State private var confirmDelete = false

    init(taskId: String, onDeleted: (() -> Void)? = nil) {
        self.taskId = taskId
        self.onDeleted = onDeleted
        _model = StateObject(wrappedValue: TaskDetailModel(taskId: taskId, store: TaskStore.shared))
    }

    var body: some View {
        Group {
            if model.isMissing {
                ContentUnavailableView("Task not found", systemImage: "questionmark.circle",
                                       description: Text("It may have been deleted on another device."))
            } else {
                form
            }
        }
        .navigationTitle(model.task.title.isEmpty ? "Task" : model.task.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.flush() }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                model.delete()
                onDeleted?()
                dismiss()
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Button { model.toggleCompleted() } label: {
                        Image(systemName: model.task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(model.task.isCompleted ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.task.isCompleted ? "Mark as not done" : "Complete")
                    TextField("Title", text: $model.task.title, axis: .vertical)
                        .font(.title3.weight(.semibold))
                }
                TextField("Notes", text: $model.task.notes, axis: .vertical)
                    .lineLimit(3...12)
            }

            whenSection
            datesSection
            repeatSection
            organizeSection
            tagsSection
            checklistSection
            statusSection
            infoSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - When / dates

    private var whenSection: some View {
        Section("When") {
            Picker("When", selection: bucketBinding) {
                Text("Anytime").tag(TaskScheduleBucket.anytime)
                Text("Today").tag(TaskScheduleBucket.today)
                Text("Evening").tag(TaskScheduleBucket.evening)
                Text("Someday").tag(TaskScheduleBucket.someday)
            }
            .pickerStyle(.segmented)

            Toggle("Start Date", isOn: model.hasStartBinding)
            if model.task.startAt != nil {
                DatePicker("Starts", selection: model.startDayBinding, displayedComponents: .date)
            }

            Picker("Duration", selection: durationBinding) {
                Text("None").tag(0)
                ForEach(durationChoices, id: \.self) { minutes in
                    Text(TaskQuickAddPlanner.durationLabel(minutes).replacingOccurrences(of: "~", with: "")).tag(minutes)
                }
            }
        }
    }

    private var datesSection: some View {
        Section("Due & Reminder") {
            Toggle("Due Date", isOn: dueToggle)
            if model.task.dueAt != nil {
                DatePicker("Due", selection: model.dueDayBinding, displayedComponents: .date)
                Toggle("Time", isOn: model.dueHasTimeBinding)
                if model.dueHasTime {
                    DatePicker("At", selection: model.dueDateTimeBinding, displayedComponents: .hourAndMinute)
                }
            }
            Toggle("Remind Me", isOn: model.hasReminderBinding)
            if model.task.remindAt != nil {
                DatePicker("Reminder", selection: model.reminderBinding,
                           displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var repeatSection: some View {
        Section {
            NavigationLink {
                TaskRecurrenceEditor(rrule: repeatBinding, anchor: model.task.dueAt ?? Date())
            } label: {
                LabeledContent("Repeat", value: model.repeatSummary)
            }
        } footer: {
            if model.task.recurrenceRule != nil {
                Text("Completing it moves the due date to the next occurrence.")
            }
        }
    }

    // MARK: - Organize

    private var organizeSection: some View {
        Section("Organize") {
            Picker("Priority", selection: $model.task.priority) {
                Text("None").tag(TodoTask.Priority?.none)
                ForEach(TodoTask.Priority.allCases, id: \.self) { priority in
                    Text(priority.rawValue).tag(TodoTask.Priority?.some(priority))
                }
            }

            Picker("Project", selection: projectBinding) {
                Text("None (Inbox)").tag(String?.none)
                ForEach(model.projects) { project in
                    Label(project.name, systemImage: project.icon ?? "folder").tag(String?.some(project.id))
                }
            }

            if model.task.projectId != nil, !model.headings.isEmpty {
                Picker("Heading", selection: headingBinding) {
                    Text("None").tag(String?.none)
                    ForEach(model.headings) { heading in
                        Text(heading.title).tag(String?.some(heading.id))
                    }
                }
            }

            if model.task.projectId == nil {
                Picker("Area", selection: $model.task.areaId) {
                    Text("None").tag(String?.none)
                    ForEach(model.areas) { area in
                        Label(area.name, systemImage: area.symbol ?? "square.grid.2x2").tag(String?.some(area.id))
                    }
                }
            }
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            if !model.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.tags, id: \.self) { tag in
                            Button { model.removeTag(tag) } label: {
                                HStack(spacing: 4) {
                                    Text("#\(tag)")
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "number").foregroundStyle(.tertiary)
                TextField("Add tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        model.addTag(newTag)
                        newTag = ""
                    }
                let suggestions = model.tagSuggestions(for: newTag)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { tag in
                            Button("#\(tag)") {
                                model.addTag(tag)
                                newTag = ""
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .accessibilityLabel("Existing tags")
                }
            }
        }
    }

    private var checklistSection: some View {
        Section("Checklist") {
            ForEach(model.subtasks) { subtask in
                Button { model.toggleSubtask(subtask) } label: {
                    HStack {
                        Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.isCompleted ? Color.accentColor : Color.secondary)
                        Text(subtask.title)
                            .strikethrough(subtask.isCompleted)
                            .foregroundStyle(subtask.isCompleted ? Color.secondary : Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { model.deleteSubtask(subtask) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button { model.moveSubtask(subtask, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    Button { model.moveSubtask(subtask, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    Button(role: .destructive) { model.deleteSubtask(subtask) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            HStack {
                Image(systemName: "plus").foregroundStyle(.tertiary)
                TextField("Add item", text: $newSubtask)
                    .onSubmit {
                        model.addSubtask(newSubtask)
                        newSubtask = ""
                    }
            }
        }
    }

    private var statusSection: some View {
        Section {
            Toggle("Pinned", isOn: $model.task.isPinned)
            Button(model.task.isCancelled ? "Reopen Task" : "Won’t Do") { model.toggleCancelled() }
            Button("Delete Task", role: .destructive) { confirmDelete = true }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        if let message = model.errorMessage {
            Section { Text(message).foregroundStyle(.red) }
        }
        Section {
            LabeledContent("Created", value: model.task.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = model.task.completedAt {
                LabeledContent("Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
            }
            if model.task.sourceSessionId != nil {
                Label("From a meeting", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    // MARK: - Bindings

    private let durationPresets = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

    private var durationChoices: [Int] {
        var all = durationPresets
        if let custom = model.task.estimatedMinutes, custom > 0, !all.contains(custom) {
            all.append(custom)
            all.sort()
        }
        return all
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { model.task.estimatedMinutes ?? 0 },
            set: { model.task.estimatedMinutes = $0 > 0 ? $0 : nil }
        )
    }

    private var bucketBinding: Binding<TaskScheduleBucket> {
        Binding(
            get: { model.task.scheduleBucket },
            set: { model.setBucket($0) }
        )
    }

    private var dueToggle: Binding<Bool> {
        Binding(
            get: { model.task.dueAt != nil },
            set: { on in
                if on {
                    model.task.dueAt = Calendar.current.startOfDay(for: Date())
                } else {
                    model.task.dueAt = nil
                    // A repeat needs a due date.
                    model.task.recurrenceRule = nil
                }
            }
        )
    }

    private var repeatBinding: Binding<String?> {
        Binding(
            get: { model.task.recurrenceRule },
            set: { rule in
                if rule != nil, model.task.dueAt == nil {
                    model.task.dueAt = Calendar.current.startOfDay(for: Date())
                }
                model.task.recurrenceRule = rule
            }
        )
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { model.task.projectId },
            set: { model.moveToProject($0) }
        )
    }

    private var headingBinding: Binding<String?> {
        Binding(
            get: { model.task.headingId },
            set: { model.setHeading($0) }
        )
    }
}

// MARK: - Model

@MainActor
final class TaskDetailModel: ObservableObject {
    @Published var task: TodoTask {
        didSet { if task != oldValue, loaded { scheduleSave() } }
    }
    @Published private(set) var isMissing = false
    @Published private(set) var subtasks: [TaskSubtask] = []
    @Published private(set) var tags: [String] = []
    @Published private(set) var allTags: [String] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var areas: [TaskArea] = []
    @Published private(set) var headings: [ProjectHeading] = []
    @Published var errorMessage: String?

    private let taskId: String
    private let store: TaskStore
    /// The stored row `task`'s edits are relative to (see `TaskEditMerge`).
    private var baseline: TodoTask
    private var loaded = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var cancellables: [AnyCancellable] = []
    private var started = false

    init(taskId: String, store: TaskStore) {
        self.taskId = taskId
        self.store = store
        let placeholder = TodoTask(id: taskId, title: "")
        self.task = placeholder
        self.baseline = placeholder
        reload()
    }

    func start() {
        guard !started else { return }
        started = true
        // Follow the row: completion from the list beside the editor (iPad),
        // a snooze, or a sync round must show here and not be overwritten.
        cancellables.append(store.observeTask(id: taskId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.storeDidChange($0) }))
        cancellables.append(store.observeSubtasks(taskId: taskId)
            .replaceError(with: [])
            .sink { [weak self] in self?.subtasks = $0 })
        cancellables.append(store.observeProjects()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.projects = $0 }))
        cancellables.append(store.observeAreas()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.areas = $0 }))
        allTags = (try? store.allTags()) ?? []
        loadHeadings()
    }

    private func reload() {
        loaded = false
        defer { loaded = true }
        guard let fresh = try? store.fetchTask(id: taskId) else {
            isMissing = true
            return
        }
        isMissing = false
        baseline = fresh
        task = fresh
        tags = (try? store.tags(for: taskId)) ?? []
    }

    /// The stored row changed (here or elsewhere). Pending edits are replayed
    /// onto it; without any, the editor simply shows it.
    private func storeDidChange(_ fresh: TodoTask?) {
        guard let fresh else {
            // Deleted elsewhere: drop pending edits instead of re-saving.
            saveTask?.cancel()
            dirty = false
            isMissing = true
            return
        }
        isMissing = false
        let shown = dirty ? TaskEditMerge.rebased(edited: task, baseline: baseline, onto: fresh) : fresh
        let projectChanged = shown.projectId != task.projectId
        baseline = fresh
        if shown != task {
            loaded = false
            task = shown
            loaded = true
        }
        tags = (try? store.tags(for: taskId)) ?? tags
        if projectChanged { loadHeadings() }
    }

    private func loadHeadings() {
        if let projectId = task.projectId {
            headings = (try? store.headings(in: projectId)) ?? []
        } else {
            headings = []
        }
    }

    // MARK: Autosave

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard dirty, !isMissing else { return }
        dirty = false
        do {
            // Replay only this editor's edits onto the row as stored now, so
            // changes made elsewhere since it loaded aren't overwritten.
            guard let current = try store.fetchTask(id: taskId) else {
                isMissing = true
                return
            }
            var toSave = TaskEditMerge.rebased(edited: task, baseline: baseline, onto: current)
            if toSave.projectId != nil { toSave.areaId = nil }
            if toSave.recurrenceRule != nil, toSave.dueAt == nil {
                toSave.dueAt = Calendar.current.startOfDay(for: Date())
            }
            try store.updateTask(toSave)
            baseline = toSave
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a dedicated store write after saving pending edits, then reloads.
    private func write(_ work: () throws -> Void) {
        flush()
        do {
            try work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    // MARK: Fields

    var dueHasTime: Bool {
        guard let due = task.dueAt else { return false }
        return PlannerTimeOfDay.hasTime(due, calendar: .current)
    }

    var repeatSummary: String {
        guard let raw = task.recurrenceRule else { return "Never" }
        return (try? RecurrenceRule.parse(raw))?.summary ?? raw
    }

    /// 9:00 on the due day (today when undated, or the next hour if 9:00
    /// has passed).
    var defaultReminderDate: Date {
        let cal = Calendar.current
        let day = task.dueAt.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        if morning > Date() { return morning }
        let nextHour = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return cal.date(bySetting: .minute, value: 0, of: nextHour) ?? nextHour
    }

    func setBucket(_ bucket: TaskScheduleBucket) {
        task = TaskDestinationDrop.planned(task, bucket: bucket, calendar: .current, now: Date())
    }

    // Bindings capture only `self` (no key paths), so they stay Sendable.

    var hasStartBinding: Binding<Bool> {
        Binding(
            get: { self.task.startAt != nil },
            set: { on in self.task.startAt = on ? TaskQuickDates.tomorrow() : nil }
        )
    }

    /// The start date is date-only (stored as the start of the day).
    var startDayBinding: Binding<Date> {
        Binding(
            get: { self.task.startAt ?? Date() },
            set: { self.task.startAt = Calendar.current.startOfDay(for: $0) }
        )
    }

    var dueDateTimeBinding: Binding<Date> {
        Binding(
            get: { self.task.dueAt ?? Date() },
            set: { self.task.dueAt = $0 }
        )
    }

    var hasReminderBinding: Binding<Bool> {
        Binding(
            get: { self.task.remindAt != nil },
            set: { on in self.task.remindAt = on ? self.defaultReminderDate : nil }
        )
    }

    var reminderBinding: Binding<Date> {
        Binding(
            get: { self.task.remindAt ?? Date() },
            set: { self.task.remindAt = $0 }
        )
    }

    /// The due day, keeping any time of day.
    var dueDayBinding: Binding<Date> {
        Binding(
            get: { self.task.dueAt ?? Date() },
            set: { newDay in
                let cal = Calendar.current
                if let due = self.task.dueAt, PlannerTimeOfDay.hasTime(due, calendar: cal) {
                    let time = cal.dateComponents([.hour, .minute], from: due)
                    self.task.dueAt = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                               second: 0, of: newDay) ?? newDay
                } else {
                    self.task.dueAt = cal.startOfDay(for: newDay)
                }
            }
        )
    }

    var dueHasTimeBinding: Binding<Bool> {
        Binding(
            get: { self.dueHasTime },
            set: { on in
                let cal = Calendar.current
                guard let due = self.task.dueAt else { return }
                let day = cal.startOfDay(for: due)
                if on {
                    self.task.dueAt = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
                } else {
                    self.task.dueAt = day
                }
            }
        )
    }

    // MARK: Filing

    func moveToProject(_ projectId: String?) {
        guard projectId != task.projectId else { return }
        write { try store.moveTask(id: taskId, toProject: projectId) }
        loadHeadings()
    }

    func setHeading(_ headingId: String?) {
        write { try store.setHeading(headingId, forTask: taskId) }
    }

    func toggleCompleted() {
        write {
            if task.isCompleted { try store.uncompleteTask(id: taskId) } else { try store.completeTask(id: taskId) }
        }
    }

    func toggleCancelled() {
        write {
            if task.isCancelled { try store.uncancelTask(id: taskId) } else { try store.cancelTask(id: taskId) }
        }
    }

    func delete() {
        saveTask?.cancel()
        dirty = false
        do { try store.deleteTask(id: taskId) } catch { errorMessage = error.localizedDescription }
        isMissing = true
    }

    // MARK: Tags

    func addTag(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        guard !cleaned.isEmpty, !tags.contains(cleaned) else { return }
        saveTags(tags + [cleaned])
    }

    func removeTag(_ tag: String) {
        saveTags(tags.filter { $0 != tag })
    }

    func tagSuggestions(for prefix: String) -> [String] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allTags.filter { !tags.contains($0) && (typed.isEmpty || $0.hasPrefix(typed)) }.prefix(12).map { $0 }
    }

    private func saveTags(_ newTags: [String]) {
        write {
            try store.setTags(newTags, for: taskId)
            // Touch the row so lists observing `tasks` pick up the new tags.
            if let current = try store.fetchTask(id: taskId) { try store.updateTask(current) }
        }
        allTags = (try? store.allTags()) ?? allTags
    }

    // MARK: Checklist

    func addSubtask(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { _ = try store.addSubtask(to: taskId, title: trimmed) } catch { errorMessage = error.localizedDescription }
    }

    func toggleSubtask(_ subtask: TaskSubtask) {
        do { try store.setSubtaskCompleted(id: subtask.id, isCompleted: !subtask.isCompleted) }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteSubtask(_ subtask: TaskSubtask) {
        do { try store.deleteSubtask(id: subtask.id) } catch { errorMessage = error.localizedDescription }
    }

    func moveSubtask(_ subtask: TaskSubtask, by delta: Int) {
        var ids = subtasks.map(\.id)
        guard let index = ids.firstIndex(of: subtask.id) else { return }
        let target = index + delta
        guard target >= 0, target < ids.count else { return }
        ids.swapAt(index, target)
        do { try store.reorderSubtasks(ids, in: taskId) } catch { errorMessage = error.localizedDescription }
    }
}
