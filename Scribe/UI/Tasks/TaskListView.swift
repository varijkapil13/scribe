import SwiftUI

/// Detail-pane view for the Tasks layer (slice 2). Renders a quick-add field
/// at the top followed by a vertical list of tasks bucketed by due date.
struct TaskListView: View {

    let filter: TaskStore.Filter

    @StateObject private var viewModel: TaskListViewModel
    @State private var selectedTask: TodoTask?
    @State private var pendingDelete: TodoTask?
    @State private var collapsedBuckets: Set<String> = []
    @State private var showQuickAddDatePicker = false
    @State private var quickAddFieldHeight: CGFloat = 36

    init(filter: TaskStore.Filter) {
        self.filter = filter
        _viewModel = StateObject(wrappedValue: TaskListViewModel(filter: filter))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: quick-add + task list
            VStack(spacing: 0) {
                quickAddBar
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.top, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.md)
                    .background(DesignTokens.Palette.surface)

                Divider()

                content
            }
            .frame(minWidth: 280)

            // Right: detail panel (slides in when a task is selected)
            if let task = selectedTask {
                Divider()
                TaskDetailPanel(task: task, onDismiss: { selectedTask = nil })
                    .frame(width: 320)
                    .id(task.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(DesignTokens.Palette.surface)
        .animation(.easeOut(duration: DesignTokens.Motion.standard), value: selectedTask?.id)
        .navigationTitle(headerTitle)
        .searchable(text: $viewModel.searchQuery, prompt: "Search tasks")
        .onAppear {
            viewModel.start()
            focusQuickAddIfNeeded()
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: filter) { _, newFilter in
            viewModel.switchFilter(to: newFilter)
            selectedTask = nil
        }
        // Focus is handled directly by HighlightingQuickAddField observing .scribeFocusQuickAdd.
        .confirmationDialog(
            pendingDelete.map { "Delete \"\($0.title)\"?" } ?? "Delete task?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let task = pendingDelete {
                    viewModel.delete(task)
                    if task.id == selectedTask?.id { selectedTask = nil }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .background(shortcutButtons)
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var shortcutButtons: some View {
        VStack(spacing: 0) {
            Button("New task") {
                NotificationCenter.default.post(name: .scribeFocusQuickAdd, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])
            Button("Toggle complete") {
                if let id = viewModel.focusedTaskId,
                   let task = focusedTask(id: id) {
                    viewModel.toggleCompleted(task)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(viewModel.focusedTaskId == nil)
            Button("Delete") {
                if let id = viewModel.focusedTaskId,
                   let task = focusedTask(id: id) {
                    pendingDelete = task
                }
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(viewModel.focusedTaskId == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func focusedTask(id: String) -> TodoTask? {
        for group in viewModel.groups {
            if let task = group.tasks.first(where: { $0.id == id }) { return task }
        }
        return viewModel.searchResults.first(where: { $0.id == id })
    }

    // MARK: - Focus

    private func focusQuickAddIfNeeded() {
        guard filter == .today || filter == .inbox else { return }
        // Small async hop so NSTextField's notification observer is registered
        // before the post fires (makeNSView runs during the same layout pass as onAppear).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .scribeFocusQuickAdd, object: nil)
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        switch filter {
        case .inbox:        return "Inbox"
        case .today:        return "Today"
        case .upcoming:     return "Upcoming"
        case .all:          return "All Tasks"
        case .completed:    return "Completed"
        case .project(let id): return "Project · \(id.prefix(6))"
        case .tag(let tag):    return "#\(tag)"
        }
    }

    // MARK: - Quick add

    @ViewBuilder
    private var quickAddBar: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            MultilineQuickAddField(
                text: $viewModel.quickAddText,
                intrinsicHeight: $quickAddFieldHeight,
                placeholder: "Add a task — tmr, next fri, #tag, +Project, !high\nReturn for notes · Cmd+Return to save",
                onSubmit: {
                    viewModel.commitQuickAdd()
                    quickAddFieldHeight = 36
                }
            )
            .frame(maxWidth: .infinity, minHeight: quickAddFieldHeight, maxHeight: quickAddFieldHeight)

            // Calendar date picker — tinted when a date is selected
            Button { showQuickAddDatePicker.toggle() } label: {
                Image(systemName: viewModel.quickAddDueDate != nil
                      ? "calendar.badge.clock"
                      : "calendar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(viewModel.quickAddDueDate != nil
                                     ? Color.orange
                                     : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .popover(isPresented: $showQuickAddDatePicker, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: $viewModel.quickAddDueDate)
                    .padding(4)
            }
            .help(viewModel.quickAddDueDate.map {
                "Due: \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? "Pick due date")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            searchContent
        } else if viewModel.groups.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: "Nothing here yet",
                message: emptyMessage
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    ForEach(viewModel.groups, id: \.bucket) { group in
                        section(for: group.bucket, tasks: group.tasks)
                    }
                }
                .padding(DesignTokens.Spacing.xl)
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.searchResults.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Try a different word or part of a word."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("\(viewModel.searchResults.count) result\(viewModel.searchResults.count == 1 ? "" : "s")")
                        .eyebrowStyle()
                        .padding(.bottom, DesignTokens.Spacing.xs)
                    ForEach(viewModel.searchResults) { task in
                        taskRow(for: task)
                    }
                }
                .padding(DesignTokens.Spacing.xl)
            }
        }
    }

    @ViewBuilder
    private func taskRow(for task: TodoTask) -> some View {
        TaskRowView(
            task: task,
            isRecentlyCompleted: viewModel.recentlyCompletedRecurring.contains(task.id),
            tags: viewModel.tags(for: task.id),
            isFocused: selectedTask?.id == task.id,
            onToggle: { viewModel.toggleCompleted(task) },
            onOpen: {
                viewModel.focusedTaskId = task.id
                withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                    selectedTask = task
                }
            }
        )
        .onTapGesture {
            viewModel.focusedTaskId = task.id
            withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                selectedTask = (selectedTask?.id == task.id) ? nil : task
            }
        }
        .overlay(
            selectedTask?.id == task.id
                ? RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                : nil
        )
        .draggable(TaskDragPayload(id: task.id))
        .contextMenu {
            Button {
                withAnimation { selectedTask = task }
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = task
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .inbox:    return "Tasks without a project show up here."
        case .today:    return "Nothing due today."
        case .upcoming: return "No tasks due in the next 7 days."
        case .completed: return "Completed tasks will appear here."
        default:        return "Add a task with the field above to get started."
        }
    }

    @ViewBuilder
    private func section(for bucket: TaskListViewModel.Bucket, tasks: [TodoTask]) -> some View {
        let isCollapsed = collapsedBuckets.contains(bucket.title)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isCollapsed {
                        collapsedBuckets.remove(bucket.title)
                    } else {
                        collapsedBuckets.insert(bucket.title)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(bucket.title)
                        .eyebrowStyle()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .animation(.easeOut(duration: 0.18), value: isCollapsed)
                    Spacer()
                    Text("\(tasks.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, DesignTokens.Spacing.xxs)

            if !isCollapsed {
                ForEach(tasks) { task in
                    taskRow(for: task)
                }
            }
        }
    }
}

// MARK: - Row

/// Single-row presentation: completion checkbox, title, optional metadata
/// chips (priority, due date). Tapping the body opens the task editor sheet;
/// the checkbox toggle stays separate so it can't accidentally launch a sheet.
struct TaskRowView: View {
    let task: TodoTask
    let isRecentlyCompleted: Bool
    let tags: [String]
    var isFocused: Bool = false
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .font(.system(.body, weight: .regular))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Mark complete")

            // The whole rest of the row is the click target for opening the
            // editor. Wrapping in a plain Button keeps SwiftUI's default
            // accessibility / focus behaviour without fighting the checkbox.
            Button(action: onOpen) {
                rowContent
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : DesignTokens.Palette.cardBorder,
                    lineWidth: isFocused ? 2 : 1
                )
        )
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(.body))
                    .strikethrough(task.isCompleted || isRecentlyCompleted, color: .secondary)
                    .foregroundStyle(task.isCompleted || isRecentlyCompleted ? .secondary : .primary)
                if !task.notes.isEmpty {
                    Text(LocalizedStringKey(task.notes))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(text: "#\(tag)", tint: .secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let priority = task.priority {
                PriorityChip(priority: priority)
            }

            if let due = task.dueAt {
                DueDateChip(
                    date: due,
                    isOverdue: !task.isCompleted && due < Calendar.current.startOfDay(for: Date())
                )
            }
        }
    }
}

private struct PriorityChip: View {
    let priority: TodoTask.Priority

    var body: some View {
        Text(priority.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var tint: Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        }
    }
}

private struct DueDateChip: View {
    let date: Date
    let isOverdue: Bool

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        Text(Self.formatter.string(from: date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(isOverdue ? DesignTokens.Palette.recording : .secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    isOverdue
                        ? DesignTokens.Palette.recording.opacity(0.12)
                        : Color.primary.opacity(0.05)
                )
            )
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Received by TaskListView to focus the quick-add field.
    /// Slice 8: post this from the main window key handler when a task filter is
    /// selected and the user presses Cmd-N.
    static let scribeFocusQuickAdd = Notification.Name("scribe.focusQuickAdd")
}
