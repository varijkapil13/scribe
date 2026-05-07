import SwiftUI

/// Modal editor sheet for a single task. Loads draft state into the view
/// model and only writes back on save. Cancel discards. Toolbar exposes
/// Delete (destructive, with confirm) and Duplicate.
struct TaskEditorView: View {

    @StateObject private var viewModel: TaskEditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hasReminder: Bool
    @State private var showDeleteConfirm = false
    @State private var showDueDatePicker = false
    @State private var showReminderPicker = false
    // Preserved so toggling off then on restores the original date.
    @State private var lastRemindDate: Date?

    init(task: TodoTask) {
        _viewModel = StateObject(wrappedValue: TaskEditorViewModel(task: task))
        _hasReminder = State(initialValue: task.remindAt != nil)
        _lastRemindDate = State(initialValue: task.remindAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $viewModel.title)
                    TextField("Notes", text: $viewModel.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Schedule") {
                    // Due date — calendar popover button
                    HStack {
                        Label("Due date", systemImage: "calendar")
                        Spacer()
                        Button {
                            showDueDatePicker.toggle()
                        } label: {
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
                            InlineDatePickerView(selectedDate: $viewModel.dueAt)
                                .padding(4)
                        }
                    }

                    // Time row — only visible when a due date is set
                    if viewModel.dueAt != nil {
                        DatePicker(
                            "Time",
                            selection: Binding(
                                get: { viewModel.dueAt ?? Date() },
                                set: { viewModel.dueAt = $0 }
                            ),
                            displayedComponents: [.hourAndMinute]
                        )
                    }

                    Toggle("Reminder", isOn: $hasReminder)
                        .onChange(of: hasReminder) { _, on in
                            if on {
                                viewModel.remindAt = lastRemindDate ?? viewModel.dueAt ?? Calendar.current.startOfDay(for: Date())
                            } else {
                                lastRemindDate = viewModel.remindAt
                                viewModel.remindAt = nil
                            }
                        }
                    if hasReminder {
                        HStack {
                            Label("Remind at", systemImage: "bell")
                            Spacer()
                            Button {
                                showReminderPicker.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(reminderDateLabel)
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
                                InlineDatePickerView(selectedDate: $viewModel.remindAt)
                                    .padding(4)
                            }
                        }
                        if viewModel.remindAt != nil {
                            DatePicker(
                                "Reminder time",
                                selection: Binding(
                                    get: { viewModel.remindAt ?? Date() },
                                    set: { viewModel.remindAt = $0 }
                                ),
                                displayedComponents: [.hourAndMinute]
                            )
                        }
                    }
                }

                Section("Organization") {
                    Picker("Priority", selection: $viewModel.priority) {
                        Text("None").tag(TodoTask.Priority?.none)
                        ForEach(TodoTask.Priority.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(Optional(p))
                        }
                    }

                    Picker("Project", selection: $viewModel.projectId) {
                        Text("Inbox (no project)").tag(String?.none)
                        ForEach(viewModel.availableProjects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }

                    TextField("Tags (comma-separated)", text: $viewModel.tagsInput)
                }

                if let title = viewModel.sourceSessionTitle {
                    Section("Source") {
                        Label(title, systemImage: "waveform.badge.mic")
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = viewModel.saveError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DesignTokens.Palette.recording)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        _ = viewModel.duplicate()
                        dismiss()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .help("Create a copy of this task")

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete this task")

                    Button("Save") {
                        if viewModel.save() { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .confirmationDialog(
                "Delete this task?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    viewModel.delete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This can't be undone.")
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 640)
    }

    // MARK: - Helpers

    private var dueDateLabel: String {
        guard let date = viewModel.dueAt else { return "No date" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var reminderDateLabel: String {
        guard let date = viewModel.remindAt else { return "No date" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
