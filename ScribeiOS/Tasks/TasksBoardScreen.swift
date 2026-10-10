import SwiftUI
import UIKit

/// Kanban board for a task list, built on the Mac's pure board logic
/// (`TaskBoardLayout` columns, `TaskBoardMove` drop outcomes). Cards drag
/// between columns to change status, project or priority.
struct TasksBoardScreen: View {
    let destination: TaskListDestination
    @ObservedObject var model: TasksListModel
    @ObservedObject var library: TasksLibraryModel
    let grouping: TaskBoardGrouping
    /// iPad: open in the detail column. Nil (iPhone): push.
    var onOpenTask: ((String) -> Void)?

    @State private var targetedColumn: String?

    private var actions: TaskMobileActions { .live }

    private var columns: [TaskBoardColumn] {
        let projectAreas = Dictionary(
            library.projects.compactMap { project in project.areaId.map { (project.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let done = grouping == .status ? model.boardDone(projectAreaIds: projectAreas) : []
        return TaskBoardLayout.columns(active: model.tasks, done: done, grouping: grouping,
                                       projects: boardProjects)
    }

    /// Inside a project list only that project gets a column; elsewhere every
    /// project does.
    private var boardProjects: [Project] {
        if case .project(let id) = destination { return library.projects.filter { $0.id == id } }
        if case .area(let id) = destination { return library.projects(inArea: id) }
        return library.projects
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    columnView(column)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func columnView(_ column: TaskBoardColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: column.systemImage)
                    .foregroundStyle(TasksColor.from(hex: column.colorHex) ?? Color.secondary)
                Text(column.title).font(.headline)
                Spacer()
                Text("\(column.tasks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(column.tasks) { task in
                        card(task)
                    }
                    if column.tasks.isEmpty {
                        Text("Drop tasks here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, lineWidth: targetedColumn == column.id ? 2 : 0)
        )
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: column.key)
        } isTargeted: { targeted in
            if targeted { targetedColumn = column.id } else if targetedColumn == column.id { targetedColumn = nil }
        }
    }

    @ViewBuilder
    private func card(_ task: TodoTask) -> some View {
        let content = MobileTaskRow(
            task: task,
            projectName: library.project(task.projectId)?.name,
            tags: model.tagsByTask[task.id] ?? [],
            subtaskProgress: model.progress[task.id],
            showsProject: grouping != .project,
            onToggle: { actions.toggleCompleted(task) }
        )
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemBackground)))

        Group {
            if let onOpenTask {
                Button { onOpenTask(task.id) } label: { content }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: TaskRouteID(id: task.id)) { content }
                    .buttonStyle(.plain)
            }
        }
        .contextMenu {
            TaskRowContextMenu(task: task, projects: library.projects, headings: [],
                               onOpen: onOpenTask == nil ? nil : { onOpenTask?(task.id) }, actions: actions)
        }
        .draggable(TaskDragToken.encode(task.id)) {
            Text(task.title.isEmpty ? "Task" : task.title)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func drop(_ tokens: [String], on key: TaskBoardColumnKey) -> Bool {
        var handled = false
        for token in tokens {
            guard let id = TaskDragToken.decode(token), let task = try? TaskStore.shared.fetchTask(id: id) else { continue }
            let outcome = TaskBoardMove.outcome(dropping: task, into: key, calendar: .current, now: Date())
            actions.apply(outcome, to: task)
            handled = true
        }
        targetedColumn = nil
        return handled
    }
}
