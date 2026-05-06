import Combine
import Foundation
import SwiftUI

/// Drives the sidebar's Projects subsection. Observes `TaskStore` so the
/// sidebar refreshes the moment a project is created, renamed, reordered,
/// or deleted.
@MainActor
final class ProjectsViewModel: ObservableObject {

    @Published private(set) var projects: [Project] = []

    private let store: TaskStore
    private var cancellable: AnyCancellable?

    init(store: TaskStore = TaskStore()) {
        self.store = store
    }

    func start() {
        cancellable = store.observeProjects()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] in self?.projects = $0 }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
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
