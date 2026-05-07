import SwiftUI

/// Inline side-panel for viewing and editing a single task. Shown to the right
/// of the task list; replaces the old modal sheet within `TaskListView`.
///
/// `TaskEditorView` (modal sheet) is kept for uses outside the task list
/// (e.g. TranscriptDetailView action-item conversion).
struct TaskDetailPanel: View {

    let task: TodoTask
    var onDismiss: () -> Void

    @StateObject private var viewModel: TaskEditorViewModel
    @State private var showDeleteConfirm = false
    @State private var showDueDatePicker = false
    @State private var showReminderPicker = false
    @State private var hasReminder: Bool
    @State private var lastRemindDate: Date?

    init(task: TodoTask, onDismiss: @escaping () -> Void) {
        self.task = task
        self.onDismiss = onDismiss
        _viewModel = StateObject(wrappedValue: TaskEditorViewModel(task: task))
        _hasReminder = State(initialValue: task.remindAt != nil)
        _lastRemindDate = State(initialValue: task.remindAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    notesBlock
                    Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                    scheduleBlock
                    Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                    organizationBlock
                    if let title = viewModel.sourceSessionTitle {
                        Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                        sourceBlock(title: title)
                    }
                    if let err = viewModel.saveError {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(DesignTokens.Spacing.lg)
                    }
                }
            }
            Divider()
            footer
        }
        .background(DesignTokens.Palette.surface)
        .confirmationDialog(
            "Delete \"\(viewModel.title)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.delete()
                onDismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            TextField("Title", text: $viewModel.title, axis: .vertical)
                .font(.system(.title3, weight: .semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Close (discard changes)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(DesignTokens.Spacing.lg)
    }

    // MARK: - Notes

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Notes")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            MarkdownEditorView(
                text: $viewModel.notes,
                placeholder: "Add notes…",
                font: .systemFont(ofSize: NSFont.systemFontSize)
            )
            .frame(minHeight: 120)
            .background(DesignTokens.Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        }
        .padding(DesignTokens.Spacing.lg)
    }

    // MARK: - Schedule

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelRow(icon: "calendar", label: "Due date") {
                Button { showDueDatePicker.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(dueDateLabel)
                            .foregroundStyle(viewModel.dueAt != nil ? .primary : .secondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showDueDatePicker, arrowEdge: .trailing) {
                    InlineDatePickerView(selectedDate: $viewModel.dueAt).padding(4)
                }
            }

            if viewModel.dueAt != nil {
                Divider().padding(.leading, 40)
                panelRow(icon: "clock", label: "Time") {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { viewModel.dueAt ?? Date() },
                            set: { viewModel.dueAt = $0 }
                        ),
                        displayedComponents: [.hourAndMinute]
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            Divider().padding(.leading, 40)
            panelRow(icon: "bell", label: "Reminder") {
                if hasReminder {
                    Button { showReminderPicker.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(reminderLabel)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showReminderPicker, arrowEdge: .trailing) {
                        InlineDatePickerView(selectedDate: $viewModel.remindAt).padding(4)
                    }

                    Button {
                        lastRemindDate = viewModel.remindAt
                        viewModel.remindAt = nil
                        hasReminder = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("Set") {
                        viewModel.remindAt = lastRemindDate ?? viewModel.dueAt ?? Calendar.current.startOfDay(for: Date())
                        hasReminder = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Organization

    private var organizationBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelRow(icon: "flag", label: "Priority") {
                Picker("", selection: $viewModel.priority) {
                    Text("None").tag(TodoTask.Priority?.none)
                    ForEach(TodoTask.Priority.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(Optional(p))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 120)
            }

            Divider().padding(.leading, 40)
            panelRow(icon: "folder", label: "Project") {
                Picker("", selection: $viewModel.projectId) {
                    Text("Inbox").tag(String?.none)
                    ForEach(viewModel.availableProjects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 140)
            }

            Divider().padding(.leading, 40)
            panelRow(icon: "tag", label: "Tags") {
                TextField("comma-separated", text: $viewModel.tagsInput)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Source

    private func sourceBlock(title: String) -> some View {
        panelRow(icon: "waveform.badge.mic", label: "From") {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                viewModel.duplicate()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Duplicate task")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete task")

            Spacer()

            Button("Close") {
                _ = viewModel.save()
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Row helper

    private func panelRow<T: View>(
        icon: String,
        label: String,
        @ViewBuilder value: () -> T
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(label)
                .font(.system(.callout))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var dueDateLabel: String {
        guard let date = viewModel.dueAt else { return "No date" }
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInTomorrow(date)  { return "Tomorrow" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var reminderLabel: String {
        guard let date = viewModel.remindAt else { return "No date" }
        let cal = Calendar.current
        if cal.isDateInToday(date)    { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
