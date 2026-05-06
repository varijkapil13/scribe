import SwiftUI

/// Detail-pane view for the Tasks layer (slice 2). Renders a quick-add field
/// at the top followed by a vertical list of tasks bucketed by due date.
struct TaskListView: View {

    let filter: TaskStore.Filter

    @StateObject private var viewModel: TaskListViewModel
    @FocusState private var quickAddFocused: Bool
    @State private var editingTask: TodoTask?

    init(filter: TaskStore.Filter) {
        self.filter = filter
        _viewModel = StateObject(wrappedValue: TaskListViewModel(filter: filter))
    }

    var body: some View {
        VStack(spacing: 0) {
            quickAddBar
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.top, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.md)
                .background(DesignTokens.Palette.surface)

            Divider()

            content
        }
        .background(DesignTokens.Palette.surface)
        .navigationTitle(headerTitle)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        // Filter switches are handled by .id(filter) in MainWindowView, which tears down and
        // recreates this view (and its @StateObject) — no onChange needed here.
        .onReceive(NotificationCenter.default.publisher(for: .scribeFocusQuickAdd)) { _ in
            quickAddFocused = true
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
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
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("Add a task — press Return to save", text: $viewModel.quickAddText)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($quickAddFocused)
                .onSubmit { viewModel.commitQuickAdd() }
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
        if viewModel.groups.isEmpty {
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
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(bucket.title)
                .eyebrowStyle()
                .padding(.bottom, DesignTokens.Spacing.xxs)

            ForEach(tasks) { task in
                TaskRowView(
                    task: task,
                    onToggle: { viewModel.toggleCompleted(task) },
                    onOpen: { editingTask = task }
                )
                .contextMenu {
                    Button {
                        editingTask = task
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        viewModel.delete(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
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
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(.body))
                    .strikethrough(task.isCompleted, color: .secondary)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
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
