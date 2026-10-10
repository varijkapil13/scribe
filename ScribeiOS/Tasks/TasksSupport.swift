import Combine
import Foundation
import SwiftUI

// Shared plumbing for the iPhone / iPad task screens: navigation values, the
// library model (projects, areas, tags, counts), task actions and small
// view helpers.

// MARK: - Navigation

/// Navigation value for opening a task (wrapped so it never collides with
/// the plain `String` note ids other stacks push).
struct TaskRouteID: Hashable {
    let id: String
}

/// A request to open a task from outside a scene's view tree (a tapped
/// reminder notification, the planner on iPhone). The key scene's
/// `RootTabView` consumes it and routes it through its `ScribeiOSNavigator`
/// (Tasks tab → `TasksRootView`'s `.onScribeOpenRequest(.task)`).
@MainActor
final class TasksOpenRequest: ObservableObject {
    static let shared = TasksOpenRequest()

    @Published var taskId: String?

    func open(_ taskId: String) {
        self.taskId = taskId
    }
}

// MARK: - Library

/// Live projects, areas, tags and open tasks for sidebars, pickers and
/// counts. One per root screen.
@MainActor
final class TasksLibraryModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var areas: [TaskArea] = []
    @Published private(set) var tags: [String] = []
    /// Every open task (the store's `.all` filter).
    @Published private(set) var openTasks: [TodoTask] = []

    let store: TaskStore
    private var cancellables: [AnyCancellable] = []
    private var started = false

    init(store: TaskStore) {
        self.store = store
    }

    func start() {
        guard !started else { return }
        started = true
        cancellables.append(store.observeProjects()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.projects = $0 }))
        cancellables.append(store.observeAreas()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.areas = $0 }))
        cancellables.append(store.observeTasks(filter: .all)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] tasks in
                self?.openTasks = tasks
                self?.reloadTags()
            }))
    }

    private func reloadTags() {
        let fresh = (try? store.allTags()) ?? []
        if fresh != tags { tags = fresh }
    }

    func project(_ id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func area(_ id: String?) -> TaskArea? {
        guard let id else { return nil }
        return areas.first { $0.id == id }
    }

    /// Projects not filed under any (existing) area.
    var looseProjects: [Project] {
        let areaIds = Set(areas.map(\.id))
        return projects.filter { project in
            guard let areaId = project.areaId else { return true }
            return !areaIds.contains(areaId)
        }
    }

    func projects(inArea areaId: String) -> [Project] {
        projects.filter { $0.areaId == areaId }
    }

    func title(for destination: TaskListDestination) -> String {
        if let fixed = destination.fixedTitle { return fixed }
        switch destination {
        case .project(let id): return project(id)?.name ?? "Project"
        case .area(let id):    return area(id)?.name ?? "Area"
        default:               return "Tasks"
        }
    }

    func systemImage(for destination: TaskListDestination) -> String {
        switch destination {
        case .project(let id): return project(id)?.icon ?? destination.systemImage
        case .area(let id):    return area(id)?.symbol ?? destination.systemImage
        default:               return destination.systemImage
        }
    }

    func count(for destination: TaskListDestination) -> Int? {
        let now = Date()
        switch destination {
        case .project(let id):
            let n = openTasks.filter { $0.projectId == id }.count
            return n == 0 ? nil : n
        default:
            let n = TaskListSectioning.count(for: destination, in: openTasks, now: now, calendar: .current)
            return n == 0 ? nil : n
        }
    }

    var overdueCount: Int {
        TaskListSectioning.overdueCount(in: openTasks, now: Date(), calendar: .current)
    }

    // MARK: Containers

    func createProject(named name: String, inArea areaId: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let project = try store.createProject(name: trimmed)
            if let areaId { try store.setArea(areaId, forProject: project.id) }
        } catch {
            Log.ui.error("Create project failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func renameProject(_ project: Project, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = project
        updated.name = trimmed
        perform { try store.updateProject(updated) }
    }

    func moveProject(_ project: Project, toArea areaId: String?) {
        perform { try store.setArea(areaId, forProject: project.id) }
    }

    func deleteProject(_ project: Project) {
        perform { try store.deleteProject(id: project.id) }
    }

    func createArea(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { _ = try store.createArea(name: trimmed) }
    }

    func renameArea(_ area: TaskArea, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = area
        updated.name = trimmed
        perform { try store.updateArea(updated) }
    }

    func deleteArea(_ area: TaskArea) {
        perform { try store.deleteArea(id: area.id) }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch {
            Log.ui.error("Task library edit failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Actions

/// Task mutations shared by every iOS task surface (lists, Today, board,
/// planner, detail). Reminder notifications follow automatically
/// (`TasksReminderAutoScheduler` watches the tasks table).
@MainActor
struct TaskMobileActions {
    let store: TaskStore

    static var live: TaskMobileActions { TaskMobileActions(store: TaskStore.shared) }

    func toggleCompleted(_ task: TodoTask) {
        perform("toggle completion") {
            if task.isCompleted {
                try store.uncompleteTask(id: task.id)
            } else if task.isCancelled {
                try store.uncancelTask(id: task.id)
            } else {
                try store.completeTask(id: task.id)
            }
        }
    }

    func delete(_ task: TodoTask) {
        perform("delete") { try store.deleteTask(id: task.id) }
    }

    func togglePinned(_ task: TodoTask) {
        perform("pin") { try store.setPinned(!task.isPinned, for: task.id) }
    }

    func toggleCancelled(_ task: TodoTask) {
        perform("won't do") {
            if task.isCancelled { try store.uncancelTask(id: task.id) } else { try store.cancelTask(id: task.id) }
        }
    }

    func plan(_ task: TodoTask, bucket: TaskScheduleBucket) {
        let updated = TaskDestinationDrop.planned(task, bucket: bucket, calendar: .current, now: Date())
        guard updated != task else { return }
        update(updated)
    }

    /// Due date only (nil clears it, and any repeat with it).
    func setDue(_ date: Date?, for task: TodoTask) {
        var updated = task
        if let date {
            updated = TaskDestinationDrop.rescheduled(task, to: date, calendar: .current)
            updated.scheduleBucket = task.scheduleBucket == .someday ? .anytime : task.scheduleBucket
        } else {
            updated.dueAt = nil
            updated.recurrenceRule = nil
        }
        update(updated)
    }

    func setPriority(_ priority: TodoTask.Priority?, for task: TodoTask) {
        guard task.priority != priority else { return }
        var updated = task
        updated.priority = priority
        update(updated)
    }

    func move(_ task: TodoTask, toProject projectId: String?) {
        guard task.projectId != projectId else { return }
        perform("move") { try store.moveTask(id: task.id, toProject: projectId) }
    }

    func setHeading(_ headingId: String?, for task: TodoTask) {
        perform("set heading") { try store.setHeading(headingId, forTask: task.id) }
    }

    func update(_ task: TodoTask) {
        perform("update") { try store.updateTask(task) }
    }

    /// Applies a list / sidebar drop.
    func apply(_ outcome: TaskDestinationDropOutcome, to task: TodoTask) {
        switch outcome {
        case .unchanged:               break
        case .update(let updated):     update(updated)
        case .moveToProject(let id):   perform("move") { try store.moveTask(id: task.id, toProject: id) }
        case .setHeading(let id):      setHeading(id, for: task)
        case .complete:                perform("complete") { try store.completeTask(id: task.id) }
        }
    }

    /// Applies a board drop.
    func apply(_ outcome: TaskBoardDropOutcome, to task: TodoTask) {
        switch outcome {
        case .unchanged:               break
        case .update(let updated):     update(updated)
        case .complete:                perform("complete") { try store.completeTask(id: task.id) }
        case .moveToProject(let id):   perform("move") { try store.moveTask(id: task.id, toProject: id) }
        }
    }

    /// Drops the task identified by a drag token on a sidebar list. Returns
    /// whether anything was dropped.
    @discardableResult
    func drop(tokens: [String], onto destination: TaskListDestination) -> Bool {
        var handled = false
        for token in tokens {
            guard let id = TaskDragToken.decode(token), let task = try? store.fetchTask(id: id) else { continue }
            apply(TaskDestinationDrop.outcome(dropping: task, onto: destination, calendar: .current, now: Date()), to: task)
            handled = true
        }
        return handled
    }

    /// Drops dragged tasks on a list section.
    @discardableResult
    func drop(tokens: [String], ontoSection section: TaskListSection.Kind) -> Bool {
        var handled = false
        for token in tokens {
            guard let id = TaskDragToken.decode(token), let task = try? store.fetchTask(id: id) else { continue }
            apply(TaskDestinationDrop.outcome(dropping: task, ontoSection: section, calendar: .current, now: Date()), to: task)
            handled = true
        }
        return handled
    }

    // MARK: Batch

    func complete(ids: Set<String>) {
        perform("complete") { _ = try store.completeTasks(ids: Array(ids)) }
    }

    func delete(ids: Set<String>) {
        perform("delete") { _ = try store.deleteTasks(ids: Array(ids)) }
    }

    func move(ids: Set<String>, toProject projectId: String?) {
        perform("move") { try store.moveTasks(ids: Array(ids), toProject: projectId) }
    }

    func setPriority(_ priority: TodoTask.Priority?, ids: Set<String>) {
        perform("priority") { try store.setPriority(priority, forTasks: Array(ids)) }
    }

    func plan(ids: Set<String>, bucket: TaskScheduleBucket) {
        for id in ids {
            guard let task = try? store.fetchTask(id: id) else { continue }
            plan(task, bucket: bucket)
        }
    }

    func setDue(_ date: Date?, ids: Set<String>) {
        for id in ids {
            guard let task = try? store.fetchTask(id: id) else { continue }
            setDue(date, for: task)
        }
    }

    /// Persists a new manual order (per project scope).
    func reorder(_ orderedIds: [String], tasks: [TodoTask]) {
        perform("reorder") {
            for scope in TaskListSectioning.orderScopes(orderedIds, tasks: tasks) {
                try store.reorderTasks(scope.ids, in: scope.projectId)
            }
        }
    }

    private func perform(_ what: String, _ work: () throws -> Void) {
        do { try work() } catch {
            Log.ui.error("Task \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - View helpers

enum TasksColor {
    /// `#RRGGBB` → Color; nil for anything else.
    static func from(hex: String?) -> Color? {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func priority(_ priority: TodoTask.Priority?) -> Color {
        switch priority {
        case .high?:   return .red
        case .medium?: return .orange
        case .low?:    return .blue
        case nil:      return .secondary
        }
    }
}

/// Quick date choices for menus.
enum TaskQuickDates {
    static func today() -> Date { Calendar.current.startOfDay(for: Date()) }

    static func tomorrow() -> Date {
        TaskListSectioning.startOfTomorrow(now: Date(), calendar: .current)
    }

    static func nextWeek() -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 7, to: today()) ?? tomorrow()
    }
}

/// Floating "+" button (bottom trailing), also bound to ⌘N.
struct TasksAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        // No ⌘N here: the shell's menu commands own ⌘N (New Note) and
        // ⌘⇧N (New Task) — see ScribeiOSCommands.
        .accessibilityLabel("New Task")
        .padding(20)
    }
}
