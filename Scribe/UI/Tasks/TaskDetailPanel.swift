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
    @State private var showStartPicker = false
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
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    propertiesBlock
                    notesBlock
                    subtasksBlock
                    if let sessionId = viewModel.sourceSessionId {
                        sourceBlock(sessionId: sessionId, title: viewModel.sourceSessionTitle)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.top, DesignTokens.Spacing.xs)
                .padding(.bottom, DesignTokens.Spacing.xl)
            }
            Rectangle()
                .fill(DesignTokens.Palette.cardBorder(contrast))
                .frame(height: 1)
            footer
        }
        .background(DesignTokens.Palette.raised)
        .modifier(TaskHandoffModifier(taskId: task.id, title: viewModel.title))
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
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                Text("Saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
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
                    Text(viewModel.title.isEmpty ? "Untitled" : viewModel.title)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location: \(breadcrumbProjectName), \(viewModel.title.isEmpty ? "Untitled" : viewModel.title)")

                TextField("Title", text: $viewModel.title, axis: .vertical)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Field-level validation stays inline, tied to its control
                // (one-feedback-language convention — see FeedbackPolicy).
                if let validation = viewModel.validationError {
                    Text(validation)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Palette.overdue)
                        .accessibilityLabel("Title error: \(validation)")
                }
            }

            savedBadge

            Button(action: dismissSavingChanges) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DesignTokens.Palette.quietFill))
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.md)
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
            sectionHeader("Notes")

            // Task notes are a short free-text field, so a plain SwiftUI
            // TextEditor is the right fit (a full WebMarkdownEditor would be
            // overkill for a side-panel field, and pulls a WKWebView per task
            // panel). Autosave is unchanged: the binding flows into
            // TaskEditorViewModel, which debounces + persists on its own.
            ZStack(alignment: .topLeading) {
                if viewModel.notes.isEmpty {
                    Text("Add notes…")
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $viewModel.notes)
                    .font(.system(size: NSFont.systemFontSize))
                    .scrollContentBackground(.hidden)
                    .padding(2)
            }
            .frame(minHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(DesignTokens.Palette.ground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
            )
        }
    }

    // MARK: - Subtasks / checklist

    private var subtasksBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionHeader("Checklist")
            SubtaskChecklistView(taskId: task.id)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .quietListSectionHeader()
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Properties

    private var propertiesBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionHeader("Properties")
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: DesignTokens.Spacing.md,
                 verticalSpacing: DesignTokens.Spacing.sm) {
                organizationRows
                scheduleRows
                planningRows
                tagsRow
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var scheduleRows: some View {
        panelRow(label: "Due") {
            Button { showDueDatePicker.toggle() } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(dueDateLabel)
                        .foregroundStyle(viewModel.dueAt != nil ? DesignTokens.Palette.textPrimary : DesignTokens.Palette.textTertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                }
                .font(Self.valueFont)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Due date: \(dueDateLabel)")
            .popover(isPresented: $showDueDatePicker, arrowEdge: .trailing) {
                InlineDatePickerView(selectedDate: $viewModel.dueAt)
                    .padding(DesignTokens.Spacing.xs)
            }
        }

        if viewModel.dueAt != nil {
            panelRow(label: "Time") {
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

        panelRow(label: "Reminder") {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if hasReminder {
                    Button { showReminderPicker.toggle() } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text(reminderLabel)
                                .foregroundStyle(DesignTokens.Palette.textPrimary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(DesignTokens.Palette.textTertiary)
                        }
                        .font(Self.valueFont)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reminder: \(reminderLabel)")
                    .popover(isPresented: $showReminderPicker, arrowEdge: .trailing) {
                        InlineDatePickerView(selectedDate: $viewModel.remindAt)
                            .padding(DesignTokens.Spacing.xs)
                    }

                    Button {
                        lastRemindDate = viewModel.remindAt
                        viewModel.remindAt = nil
                        hasReminder = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear reminder")
                } else {
                    Button("None") {
                        viewModel.remindAt = lastRemindDate ?? viewModel.dueAt ?? Calendar.current.startOfDay(for: Date())
                        hasReminder = true
                    }
                    .buttonStyle(.plain)
                    .font(Self.valueFont)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .help("Set a reminder")
                    .accessibilityLabel("Set reminder")
                }
            }
        }
    }

    // MARK: - Planning (start date, when-bucket, duration, repeat)

    @ViewBuilder
    private var planningRows: some View {
        panelRow(label: "When") {
            Picker("", selection: Binding(
                get: { viewModel.scheduleBucket },
                set: { viewModel.setScheduleBucket($0) }
            )) {
                ForEach(TaskScheduleBucket.allCases, id: \.self) { bucket in
                    Label(bucket.title, systemImage: bucket.systemImage).tag(bucket)
                }
            }
            .quietPropertyPicker()
            .accessibilityLabel("When")
        }

        panelRow(label: "Start") {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button { showStartPicker.toggle() } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(startDateLabel)
                            .foregroundStyle(viewModel.startAt != nil ? DesignTokens.Palette.textPrimary : DesignTokens.Palette.textTertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                    }
                    .font(Self.valueFont)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this task from Today until this day")
                .accessibilityLabel("Start date: \(startDateLabel)")
                .popover(isPresented: $showStartPicker, arrowEdge: .trailing) {
                    InlineDatePickerView(selectedDate: Binding(
                        get: { viewModel.startAt },
                        set: { newValue in
                            viewModel.startAt = newValue.map { Calendar.current.startOfDay(for: $0) }
                            if newValue != nil && viewModel.scheduleBucket == .someday {
                                viewModel.scheduleBucket = .anytime
                            }
                        }
                    ))
                    .padding(DesignTokens.Spacing.xs)
                }
                if viewModel.startAt != nil {
                    Button { viewModel.startAt = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear start date")
                }
            }
        }

        panelRow(label: "Duration") {
            Menu {
                ForEach(Self.durationPresets, id: \.self) { minutes in
                    Button(TaskDurationFormat.short(minutes)) { viewModel.estimatedMinutes = minutes }
                }
                Divider()
                Button("None") { viewModel.estimatedMinutes = nil }
            } label: {
                Text(viewModel.estimatedMinutes.map(TaskDurationFormat.short) ?? "None")
                    .font(Self.valueFont)
                    .foregroundStyle(viewModel.estimatedMinutes != nil ? DesignTokens.Palette.textPrimary : DesignTokens.Palette.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Duration: \(viewModel.estimatedMinutes.map(TaskDurationFormat.short) ?? "none")")
        }

        if let summary = recurrenceSummary {
            panelRow(label: "Repeat") {
                Text(summary)
                    .font(Self.valueFont)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .lineLimit(2)
            }
        }
    }

    private static let durationPresets: [Int] = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240]

    private var startDateLabel: String {
        guard let date = viewModel.startAt else { return "Now" }
        let cal = Calendar.current
        if cal.isDateInToday(date)    { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Human summary of the task's recurrence rule (read-only in the panel).
    private var recurrenceSummary: String? {
        guard let raw = task.recurrenceRule else { return nil }
        return (try? RecurrenceRule.parse(raw))?.summary ?? raw
    }

    // MARK: - Organization

    @ViewBuilder
    private var organizationRows: some View {
        panelRow(label: "Priority") {
            Picker("", selection: $viewModel.priority) {
                Text("None").tag(TodoTask.Priority?.none)
                ForEach(TodoTask.Priority.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(Optional(p))
                }
            }
            .quietPropertyPicker()
            .accessibilityLabel("Priority")
        }

        panelRow(label: "Project") {
            Picker("", selection: Binding(
                get: { viewModel.projectId },
                set: { viewModel.selectProject($0) }
            )) {
                Text("Inbox").tag(String?.none)
                ForEach(viewModel.availableProjects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .quietPropertyPicker()
            .accessibilityLabel("Project")
        }

        if !viewModel.availableHeadings.isEmpty {
            panelRow(label: "Heading") {
                Picker("", selection: $viewModel.headingId) {
                    Text("None").tag(String?.none)
                    ForEach(viewModel.availableHeadings) { heading in
                        Text(heading.title).tag(Optional(heading.id))
                    }
                }
                .quietPropertyPicker()
                .accessibilityLabel("Heading")
            }
        }

        if !viewModel.availableAreas.isEmpty {
            panelRow(label: "Area") {
                if viewModel.projectId != nil {
                    // A project task lives in its project's area.
                    Text(areaName(viewModel.effectiveAreaId) ?? "None")
                        .font(Self.valueFont)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .help("Set by the task's project")
                } else {
                    Picker("", selection: $viewModel.areaId) {
                        Text("None").tag(String?.none)
                        ForEach(viewModel.availableAreas) { area in
                            Text(area.name).tag(Optional(area.id))
                        }
                    }
                    .quietPropertyPicker()
                    .accessibilityLabel("Area")
                }
            }
        }

    }

    private var tagsRow: some View {
        panelRow(label: "Tags") {
            TagTokenField(
                tags: viewModel.tags,
                suggestions: { viewModel.tagSuggestions(matching: $0) },
                onAdd: { viewModel.addTag($0) },
                onRemove: { viewModel.removeTag($0) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Source

    private func sourceBlock(sessionId: String, title: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionHeader("Mentioned in")
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .accessibilityHidden(true)
                sourceLink(sessionId: sessionId, title: title)
            }
        }
    }

    @ViewBuilder
    private func sourceLink(sessionId: String, title: String?) -> some View {
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
                    }
                    .font(Self.valueFont)
                }
                .buttonStyle(.link)
                .help("Open the source recording")
                .accessibilityLabel("Open source recording: \(title)")
            } else {
                // No navigation host (inspector sheets): read-only label.
                Text(title)
                    .font(Self.valueFont)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .lineLimit(1)
            }
        } else {
            // The source recording was deleted: keep the provenance visible
            // but make clear it can no longer be opened.
            Text("Recording deleted")
                .font(Self.valueFont)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .italic()
                .lineLimit(1)
                .accessibilityLabel("Source recording was deleted")
        }
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
            .foregroundStyle(DesignTokens.Palette.textSecondary)
            .help("Duplicate task")
            .accessibilityLabel("Duplicate task")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Palette.textSecondary)
            .help("Delete task")
            .accessibilityLabel("Delete task")

            Spacer()

            Button("Done") {
                dismissSavingChanges()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Row helper

    private static let valueFont = Font.system(size: 13)

    private func panelRow<T: View>(
        label: String,
        @ViewBuilder value: () -> T
    ) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .gridColumnAlignment(.leading)
                .frame(minWidth: 64, minHeight: 22, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private var dueDateLabel: String {
        guard let date = viewModel.dueAt else { return "No date" }
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInTomorrow(date)  { return "Tomorrow" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func areaName(_ id: String?) -> String? {
        guard let id else { return nil }
        return viewModel.availableAreas.first { $0.id == id }?.name
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

private extension View {
    func quietPropertyPicker() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .fixedSize()
    }
}
