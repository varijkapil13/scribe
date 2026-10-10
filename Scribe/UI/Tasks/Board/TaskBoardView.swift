import SwiftUI

/// Kanban presentation of a task list (TaskListView's Board mode). Columns
/// come from `TaskBoardLayout.columns`; dragging a card onto another column
/// updates the grouping's field through `TaskListViewModel.moveOnBoard`
/// (undoable). Every drop also has a keyboard / VoiceOver path: the card's
/// "Move to" context menu.
struct TaskBoardView: View {

    @ObservedObject var viewModel: TaskListViewModel
    let filter: TaskStore.Filter
    @Binding var grouping: TaskBoardGrouping
    let selectedTaskId: String?
    let onOpen: (TodoTask) -> Void

    @StateObject private var doneFeed: TaskBoardDoneFeed
    @State private var dropTargetColumn: String?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let columnWidth: CGFloat = 264

    init(
        viewModel: TaskListViewModel,
        filter: TaskStore.Filter,
        grouping: Binding<TaskBoardGrouping>,
        selectedTaskId: String?,
        onOpen: @escaping (TodoTask) -> Void
    ) {
        self.viewModel = viewModel
        self.filter = filter
        self._grouping = grouping
        self.selectedTaskId = selectedTaskId
        self.onOpen = onOpen
        let store = viewModel.store
        _doneFeed = StateObject(wrappedValue: TaskBoardDoneFeed(store: store))
    }

    private var columns: [TaskBoardColumn] {
        let done: [TodoTask]
        if grouping == .status {
            var areaByProject: [String: String] = [:]
            for project in viewModel.availableProjects {
                if let areaId = project.areaId { areaByProject[project.id] = areaId }
            }
            done = TaskBoardLayout.doneTasks(
                doneFeed.finished,
                filter: filter,
                tagsByTask: doneFeed.tagsByTask,
                projectAreaIds: areaByProject,
                calendar: .current,
                now: Date()
            )
        } else {
            done = []
        }
        return TaskBoardLayout.columns(
            active: viewModel.boardActiveTasks,
            done: done,
            grouping: grouping,
            projects: viewModel.availableProjects
        )
    }

    var body: some View {
        // Built once per update; every card's "Move to" menu reuses it.
        let allColumns = columns
        return VStack(spacing: 0) {
            groupingBar
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    ForEach(allColumns) { column in
                        columnView(column, allColumns: allColumns)
                    }
                }
                .padding(DesignTokens.Spacing.md)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { updateDoneFeed() }
        .onDisappear { doneFeed.stop() }
        .onChange(of: grouping) { _, _ in updateDoneFeed() }
    }

    private func updateDoneFeed() {
        if grouping == .status { doneFeed.start() } else { doneFeed.stop() }
    }

    // MARK: - Grouping bar

    private var groupingBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Group by")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Group by", selection: $grouping) {
                ForEach(TaskBoardGrouping.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Group board by")
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Column

    @ViewBuilder
    private func columnView(_ column: TaskBoardColumn, allColumns: [TaskBoardColumn]) -> some View {
        let isTargeted = dropTargetColumn == column.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: column.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(columnTint(column))
                Text(column.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(column.tasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(column.tasks) { task in
                        card(for: task, in: column, allColumns: allColumns)
                    }
                    if column.tasks.isEmpty {
                        Text("Drop tasks here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.bottom, DesignTokens.Spacing.sm)
            }
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(isTargeted
                      ? DesignTokens.Palette.accentFill(.hover, accent: accent, contrast: contrast)
                      : DesignTokens.Palette.fill(.hover, contrast: contrast))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(isTargeted ? accent : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .dropDestination(for: TaskDragPayload.self) { payloads, _ in
            guard let first = payloads.first else { return false }
            drop(taskId: first.id, on: column.key)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetColumn = column.id
            } else if dropTargetColumn == column.id {
                dropTargetColumn = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title), \(column.tasks.count) task\(column.tasks.count == 1 ? "" : "s")")
    }

    private func columnTint(_ column: TaskBoardColumn) -> Color {
        if let hex = column.colorHex, let color = Color(hex: hex) { return color }
        if case .priority(let priority) = column.key { return Self.priorityColor(priority) }
        return .secondary
    }

    // MARK: - Card

    private func card(for task: TodoTask, in column: TaskBoardColumn, allColumns: [TaskBoardColumn]) -> some View {
        TaskBoardCard(
            task: task,
            tags: tags(for: task),
            subtaskProgress: viewModel.subtaskProgress[task.id],
            projectName: grouping == .project ? nil : viewModel.project(id: task.projectId)?.name,
            isSelected: selectedTaskId == task.id,
            onToggle: { viewModel.toggleCompleted(task) }
        )
        .onTapGesture { onOpen(task) }
        .draggable(TaskDragPayload(id: task.id))
        .contextMenu {
            Button { onOpen(task) } label: { Label("Edit…", systemImage: "pencil") }
            Menu {
                ForEach(allColumns.filter { $0.key != column.key }) { target in
                    Button(target.title) { drop(taskId: task.id, on: target.key) }
                }
            } label: {
                Label("Move to", systemImage: "arrow.right.square")
            }
        }
    }

    private func tags(for task: TodoTask) -> [String] {
        let listed = viewModel.tags(for: task.id)
        return listed.isEmpty ? (doneFeed.tagsByTask[task.id] ?? []) : listed
    }

    private func drop(taskId: String, on key: TaskBoardColumnKey) {
        dropTargetColumn = nil
        var found = viewModel.task(id: taskId) ?? doneFeed.finished.first(where: { $0.id == taskId })
        if found == nil {
            found = try? viewModel.store.fetchTask(id: taskId)
        }
        guard let task = found else { return }
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            _ = viewModel.moveOnBoard(task, to: key, grouping: grouping, calendar: .current, now: Date())
        }
    }

    static func priorityColor(_ priority: TodoTask.Priority?) -> Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        case .none:   return .secondary
        }
    }
}

// MARK: - Card view

/// One board card: checkbox, title, then due · priority · subtasks · tags.
private struct TaskBoardCard: View {
    let task: TodoTask
    let tags: [String]
    let subtaskProgress: SubtaskProgress?
    let projectName: String?
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent

    private var finished: Bool { task.isCompleted || task.isCancelled }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Button(action: onToggle) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(task.isCompleted ? accent : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Complete")

                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(finished, color: .secondary)
                    .foregroundStyle(finished ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let priority = task.priority {
                    Image(systemName: Self.prioritySymbol(priority))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TaskBoardView.priorityColor(priority))
                        .accessibilityLabel("\(priority.rawValue) priority")
                }
            }

            if hasMeta {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let due = task.dueAt {
                        Label(Self.dueText(due), systemImage: "calendar")
                            .font(.system(size: 10))
                            .foregroundStyle(isOverdue(due) ? DesignTokens.Palette.recording : .secondary)
                            .lineLimit(1)
                    }
                    if let progress = subtaskProgress, progress.total > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: progress.isComplete ? "checklist.checked" : "checklist")
                            Text("\(progress.completed)/\(progress.total)").monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(progress.isComplete ? accent : .secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(progress.completed) of \(progress.total) subtasks completed")
                    }
                    if let minutes = task.estimatedMinutes, minutes > 0 {
                        Text(TaskDurationFormat.short(minutes))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let projectName {
                        Text(projectName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            if !tags.isEmpty {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(tags.prefix(4), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    if tags.count > 4 {
                        Text("+\(tags.count - 4)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(isSelected ? accent : DesignTokens.Palette.cardBorder(contrast),
                              lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var hasMeta: Bool {
        task.dueAt != nil
            || (subtaskProgress?.total ?? 0) > 0
            || (task.estimatedMinutes ?? 0) > 0
            || projectName != nil
    }

    private func isOverdue(_ due: Date) -> Bool {
        !finished && due < Calendar.current.startOfDay(for: Date())
    }

    private static func prioritySymbol(_ priority: TodoTask.Priority) -> String {
        switch priority {
        case .high:   return DesignTokens.Palette.prioritySymbolHigh
        case .medium: return DesignTokens.Palette.prioritySymbolMedium
        case .low:    return DesignTokens.Palette.prioritySymbolLow
        }
    }

    /// "Today", "Tomorrow", "Mar 12" — plus the time when the due has one.
    private static func dueText(_ due: Date) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(due) {
            day = "Today"
        } else if cal.isDateInTomorrow(due) {
            day = "Tomorrow"
        } else if cal.isDateInYesterday(due) {
            day = "Yesterday"
        } else {
            day = due.formatted(.dateTime.month(.abbreviated).day())
        }
        guard cal.startOfDay(for: due) != due else { return day }
        return "\(day) \(due.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Toolbar picker

/// List / Board segmented toggle shown in TaskListView's toolbar.
struct TaskLayoutModePicker: View {
    @Binding var mode: TaskListLayoutMode

    var body: some View {
        Picker("Layout", selection: $mode) {
            ForEach(TaskListLayoutMode.allCases) { option in
                Label(option.title, systemImage: option.systemImage).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show tasks as a list or a board")
        .accessibilityLabel("Task layout")
    }
}
