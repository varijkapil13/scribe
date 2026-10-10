import Combine
import Foundation
import SwiftUI

/// Live data for one task list: its tasks (store filter + client-side
/// membership), sections, tags, checklist progress, project headings, the
/// tag filter, and — while the board is shown — the recently finished tasks
/// for the board's Done column.
@MainActor
final class TasksListModel: ObservableObject {
    let destination: TaskListDestination

    @Published private(set) var tasks: [TodoTask] = []
    @Published private(set) var sections: [TaskListSection] = []
    @Published private(set) var headings: [ProjectHeading] = []
    @Published private(set) var tagsByTask: [String: [String]] = [:]
    @Published private(set) var progress: [String: SubtaskProgress] = [:]
    @Published private(set) var finished: [TodoTask] = []
    @Published var requiredTags: Set<String> = [] {
        didSet { if requiredTags != oldValue { rebuild() } }
    }

    private let store: TaskStore
    private var raw: [TodoTask] = []
    private var projects: [Project] = []
    private var cancellables: [AnyCancellable] = []
    private var headingsCancellable: AnyCancellable?
    private var finishedCancellable: AnyCancellable?
    private var started = false

    init(destination: TaskListDestination, store: TaskStore) {
        self.destination = destination
        self.store = store
    }

    func start() {
        guard !started else { return }
        started = true
        cancellables.append(store.observeTasks(filter: destination.storeFilter)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] tasks in
                self?.raw = tasks
                self?.reloadDecorations()
                self?.rebuild()
            }))
        cancellables.append(store.observeProjects()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] projects in
                self?.projects = projects
                self?.rebuild()
            }))
        if case .project(let projectId) = destination {
            headingsCancellable = store.observeHeadings(projectId: projectId)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] headings in
                    self?.headings = headings
                    self?.rebuild()
                })
        }
    }

    /// Starts / stops reading finished tasks (the board's Done column).
    func setObservesFinished(_ on: Bool) {
        guard on else {
            finishedCancellable = nil
            finished = []
            return
        }
        guard finishedCancellable == nil else { return }
        finishedCancellable = store.observeTasks(filter: .completed)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] tasks in
                self?.finished = tasks
            })
    }

    /// Visible task ids in display order (for reordering).
    var orderedIds: [String] { sections.flatMap { $0.tasks.map(\.id) } }

    var isEmpty: Bool { sections.allSatisfy { $0.tasks.isEmpty } && headings.isEmpty }

    /// Done-column tasks scoped to this list (board, status grouping).
    func boardDone(projectAreaIds: [String: String]) -> [TodoTask] {
        TaskBoardLayout.doneTasks(finished, filter: destination.storeFilter, tagsByTask: tagsByTask,
                                  projectAreaIds: projectAreaIds, calendar: .current, now: Date())
    }

    private func reloadDecorations() {
        let ids = raw.map(\.id)
        tagsByTask = (try? store.fetchTagsForTasks(ids)) ?? [:]
        progress = (try? store.subtaskProgress(for: ids)) ?? [:]
    }

    private func rebuild() {
        let now = Date()
        let calendar = Calendar.current
        let visible = raw.filter { destination.includes($0, now: now, calendar: calendar) }
        let filtered = TaskListSectioning.filter(visible, requiringTags: requiredTags, tagsByTask: tagsByTask)
        tasks = filtered
        sections = TaskListSectioning.sections(for: destination, tasks: filtered, headings: headings,
                                               projects: projects, calendar: calendar, now: now)
    }

    // MARK: Headings

    func addHeading(_ title: String) {
        guard case .project(let projectId) = destination else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { _ = try store.createHeading(in: projectId, title: trimmed) }
    }

    func renameHeading(_ heading: ProjectHeading, to title: String) {
        perform { try store.renameHeading(id: heading.id, title: title) }
    }

    func deleteHeading(_ heading: ProjectHeading) {
        perform { try store.deleteHeading(id: heading.id) }
    }

    func moveHeading(_ heading: ProjectHeading, by delta: Int) {
        guard case .project(let projectId) = destination else { return }
        var ids = headings.map(\.id)
        guard let index = ids.firstIndex(of: heading.id) else { return }
        let target = index + delta
        guard target >= 0, target < ids.count else { return }
        ids.swapAt(index, target)
        perform { try store.reorderHeadings(ids, in: projectId) }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch {
            Log.ui.error("Task list edit failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
