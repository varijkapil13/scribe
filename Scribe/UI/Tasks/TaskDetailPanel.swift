import SwiftUI

/// Inline side-panel for viewing and editing a single task. Shown to the right
/// of the task list; replaces the old modal sheet within `TaskListView`.
///
/// Autosaves on a 500ms debounce (see `TaskEditorViewModel.setupAutoSave`) and
/// flushes any pending edit on dismiss / Close — so closing the panel (including
/// Escape) never discards work. A brief "Saved" affordance confirms each write.
///
/// This is now the single task editor everywhere: the task list shows it as a
/// side panel, and `TaskInspectorSheet` (below) hosts it as a modal sheet for
/// the calendar, note action-item conversion, and transcript convert-to-task
/// flows — replacing the old `TaskEditorView`.
struct TaskDetailPanel: View {

    let task: TodoTask
    var onDismiss: () -> Void
    /// Optional navigation hook for a task converted from a meeting: when
    /// provided, the "From: <recording>" row becomes a button that opens the
    /// source recording's transcript via this closure (passed the session id).
    /// Hosts without a navigation context (e.g. the calendar / note / transcript
    /// inspector sheets) pass nil, leaving the row a read-only label.
    var onOpenRecording: ((String) -> Void)?

    @StateObject private var viewModel: TaskEditorViewModel
    @State private var showDeleteConfirm = false
    @State private var showDueDatePicker = false
    @State private var showReminderPicker = false
    @State private var hasReminder: Bool
    @State private var lastRemindDate: Date?
    /// Drives the fading "Saved" checkmark. Set when `viewModel.lastSavedAt`
    /// changes, cleared after a short delay.
    @State private var showSavedBadge = false
    @State private var savedHideTask: Task<Void, Never>?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        task: TodoTask,
        onDismiss: @escaping () -> Void,
        onOpenRecording: ((String) -> Void)? = nil
    ) {
        self.task = task
        self.onDismiss = onDismiss
        self.onOpenRecording = onOpenRecording
        _viewModel = StateObject(wrappedValue: TaskEditorViewModel(task: task))
        _hasReminder = State(initialValue: task.remindAt != nil)
        _lastRemindDate = State(initialValue: task.remindAt)
    }

    /// Flushes any pending autosave, then dismisses. The single exit path so
    /// Close, Escape, and the X button all preserve in-flight edits.
    private func dismissSavingChanges() {
        viewModel.flush()
        onDismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    notesBlock
                    Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                    subtasksBlock
                    Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                    scheduleBlock
                    Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                    organizationBlock
                    if let sessionId = viewModel.sourceSessionId {
                        Divider().padding(.horizontal, DesignTokens.Spacing.lg)
                        sourceBlock(sessionId: sessionId, title: viewModel.sourceSessionTitle)
                    }
                }
            }
            Divider()
            footer
        }
        .scribeGlass(.hud, in: Rectangle())
        .onChange(of: viewModel.lastSavedAt) { _, newValue in
            guard newValue != nil else { return }
            flashSaved()
        }
        // Recoverable persistence failures (disk/db write failed) go to the
        // unified banner rather than inline text — one feedback language
        // (see FeedbackPolicy). The panel is hosted in several contexts without
        // an injected AppState, so route through the shared instance.
        .onChange(of: viewModel.saveError) { _, newValue in
            if let message = newValue {
                AppState.shared.report(message)
            }
        }
        .onDisappear {
            savedHideTask?.cancel()
            // Safety net: if the panel is torn down by an external selection
            // swap (a different row tapped) rather than its own Close/Escape,
            // flush any pending debounced edit so nothing is lost.
            viewModel.flush()
        }
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

    // MARK: - Saved affordance

    private func flashSaved() {
        savedHideTask?.cancel()
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            showSavedBadge = true
        }
        AccessibilityNotification.Announcement("Saved").post()
        savedHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                showSavedBadge = false
            }
        }
    }

    @ViewBuilder
    private var savedBadge: some View {
        if showSavedBadge {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
            .accessibilityHidden(true) // announced via AccessibilityNotification
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // Muted breadcrumb so the user knows where they landed after a
                // ⌘K / deep-link jump. The project name comes from the picker
                // data the panel already loads — no extra store calls.
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(breadcrumbProjectName)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                    Text(viewModel.title.isEmpty ? "Untitled" : viewModel.title)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location: \(breadcrumbProjectName), \(viewModel.title.isEmpty ? "Untitled" : viewModel.title)")

                TextField("Title", text: $viewModel.title, axis: .vertical)
                    .font(.system(.title3, weight: .semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Field-level validation stays inline, tied to its control
                // (one-feedback-language convention — see FeedbackPolicy).
                if let validation = viewModel.validationError {
                    Text(validation)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Title error: \(validation)")
                }
            }

            savedBadge

            Button(action: dismissSavingChanges) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DesignTokens.Palette.fill(.selected, contrast: contrast)))
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(DesignTokens.Spacing.lg)
    }

    /// Breadcrumb root for the task: its project's name, or "Inbox" when the
    /// task has no project. Resolved from the picker data already in memory.
    private var breadcrumbProjectName: String {
        guard let projectId = viewModel.projectId,
              let project = viewModel.availableProjects.first(where: { $0.id == projectId })
        else { return "Inbox" }
        return project.name
    }

    // MARK: - Notes

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Notes")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, DesignTokens.Spacing.xxs)

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

    // MARK: - Subtasks / checklist

    private var subtasksBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Checklist")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            SubtaskChecklistView(taskId: task.id)
        }
        .padding(DesignTokens.Spacing.lg)
    }

    // MARK: - Schedule

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelRow(icon: "calendar", label: "Due date") {
                Button { showDueDatePicker.toggle() } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
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
                .accessibilityLabel("Due date: \(dueDateLabel)")
                .popover(isPresented: $showDueDatePicker, arrowEdge: .trailing) {
                    InlineDatePickerView(selectedDate: $viewModel.dueAt)
                        .padding(DesignTokens.Spacing.xs)
                        .scribeGlass(.hud, in: Rectangle())
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
                        HStack(spacing: DesignTokens.Spacing.xs) {
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
                    .accessibilityLabel("Reminder: \(reminderLabel)")
                    .popover(isPresented: $showReminderPicker, arrowEdge: .trailing) {
                        InlineDatePickerView(selectedDate: $viewModel.remindAt)
                            .padding(DesignTokens.Spacing.xs)
                            .scribeGlass(.hud, in: Rectangle())
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
                    .accessibilityLabel("Clear reminder")
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
                .accessibilityLabel("Priority")
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
                .accessibilityLabel("Project")
            }

            Divider().padding(.leading, 40)
            panelRow(icon: "tag", label: "Tags") {
                TagTokenField(
                    tags: viewModel.tags,
                    suggestions: { viewModel.tagSuggestions(matching: $0) },
                    onAdd: { viewModel.addTag($0) },
                    onRemove: { viewModel.removeTag($0) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Source

    @ViewBuilder
    private func sourceBlock(sessionId: String, title: String?) -> some View {
        panelRow(icon: "waveform.badge.mic", label: "From") {
            if let title {
                if let onOpenRecording {
                    // The source recording still exists and we have a navigation
                    // context: offer a button that opens its transcript.
                    Button {
                        viewModel.flush()
                        onOpenRecording(sessionId)
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text(title)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.link)
                    .help("Open the source recording")
                    .accessibilityLabel("Open source recording: \(title)")
                } else {
                    // No navigation host (inspector sheets): read-only label.
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                // The source recording was deleted: keep the provenance visible
                // but make clear it can no longer be opened.
                Text("Recording deleted")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
                    .accessibilityLabel("Source recording was deleted")
            }
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
            .accessibilityLabel("Duplicate task")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete task")
            .accessibilityLabel("Delete task")

            Spacer()

            Button("Close") {
                dismissSavingChanges()
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
        .padding(.vertical, DesignTokens.Spacing.sm)
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

/// Hosts the unified ``TaskDetailPanel`` as a modal sheet for editing a task
/// outside the task-list side-panel context (calendar, note action-item
/// conversion, transcript convert-to-task). The panel autosaves + flushes on
/// dismiss, so the sheet needs no Save/Cancel of its own. Replaces the former
/// `TaskEditorView`.
struct TaskInspectorSheet: View {
    let task: TodoTask
    var onDismiss: () -> Void

    var body: some View {
        TaskDetailPanel(task: task, onDismiss: onDismiss)
            .frame(width: 400, height: 580)
    }
}
