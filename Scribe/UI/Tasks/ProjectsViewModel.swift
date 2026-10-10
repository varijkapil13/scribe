import Combine
import Foundation
import SwiftUI

/// Drives the sidebar's Projects subsection. Observes `TaskStore` so the
/// sidebar refreshes the moment a project is created, renamed, reordered,
/// or deleted.
@MainActor
final class ProjectsViewModel: ObservableObject {

    @Published private(set) var projects: [Project] = []
    /// Areas (v20) for the sidebar's Areas section and project "Area" menus.
    @Published private(set) var areas: [TaskArea] = []

    private let store: TaskStore
    private var cancellable: AnyCancellable?
    private var areasCancellable: AnyCancellable?

    init(store: TaskStore = TaskStore()) {
        self.store = store
    }

    func start() {
        cancellable = store.observeProjects()
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] in self?.projects = $0 }
            )
        areasCancellable = store.observeAreas()
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] in self?.areas = $0 }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        areasCancellable?.cancel()
        areasCancellable = nil
    }

    // MARK: - Areas

    /// Projects grouped under `areaId`, in sidebar order.
    func projectsInArea(_ areaId: String) -> [Project] {
        projects.filter { $0.areaId == areaId }
    }

    @discardableResult
    func createArea(name: String) -> TaskArea? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try store.createArea(name: trimmed)
        } catch {
            Log.ui.error("ProjectsViewModel.createArea failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func renameArea(_ area: TaskArea, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != area.name else { return }
        var copy = area
        copy.name = trimmed
        do {
            try store.updateArea(copy)
        } catch {
            Log.ui.error("ProjectsViewModel.renameArea failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteArea(id: String) {
        do {
            try store.deleteArea(id: id)
        } catch {
            Log.ui.error("ProjectsViewModel.deleteArea failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reorderAreas(from source: IndexSet, to destination: Int) {
        var ids = areas.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            try store.reorderAreas(ids)
        } catch {
            Log.ui.error("ProjectsViewModel.reorderAreas failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Files a project under an area (nil = none).
    func assignArea(_ areaId: String?, toProject projectId: String) {
        do {
            try store.setArea(areaId, forProject: projectId)
        } catch {
            Log.ui.error("ProjectsViewModel.assignArea failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Mutations

    @discardableResult
    func create(name: String, color: String?, icon: String?) -> Project? {
        do {
            return try store.createProject(name: name, color: color, icon: icon)
        } catch {
            Log.ui.error("ProjectsViewModel.create failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func update(_ project: Project) {
        do {
            try store.updateProject(project)
        } catch {
            Log.ui.error("ProjectsViewModel.update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(id: String) {
        do {
            try store.deleteProject(id: id)
        } catch {
            Log.ui.error("ProjectsViewModel.delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reorder(from source: IndexSet, to destination: Int) {
        var ids = projects.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            try store.reorderProjects(ids)
        } catch {
            Log.ui.error("ProjectsViewModel.reorder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func moveTask(taskId: String, toProject projectId: String?) {
        do {
            try store.moveTask(id: taskId, toProject: projectId)
        } catch {
            Log.ui.error("ProjectsViewModel.moveTask failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
