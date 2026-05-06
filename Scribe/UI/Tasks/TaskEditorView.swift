import SwiftUI

/// Modal editor sheet for a single task. Loads draft state into the view
/// model and only writes back on save. Cancel discards. Toolbar exposes
/// Delete (destructive, with confirm) and Duplicate.
struct TaskEditorView: View {

    @StateObject private var viewModel: TaskEditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hasDueDate: Bool
    @State private var hasReminder: Bool
    @State private var showDeleteConfirm = false

    init(task: TodoTask) {
        _viewModel = StateObject(wrappedValue: TaskEditorViewModel(task: task))
        _hasDueDate = State(initialValue: task.dueAt != nil)
        _hasReminder = State(initialValue: task.remindAt != nil)
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
                    Toggle("Due date", isOn: $hasDueDate)
                        .onChange(of: hasDueDate) { _, on in
                            viewModel.dueAt = on ? (viewModel.dueAt ?? Date()) : nil
                        }
                    if hasDueDate {
                        DatePicker(
                            "Due",
                            selection: Binding(
                                get: { viewModel.dueAt ?? Date() },
                                set: { viewModel.dueAt = $0 }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }

                    Toggle("Reminder", isOn: $hasReminder)
                        .onChange(of: hasReminder) { _, on in
                            viewModel.remindAt = on ? (viewModel.remindAt ?? viewModel.dueAt ?? Date()) : nil
                        }
                    if hasReminder {
                        DatePicker(
                            "Remind",
                            selection: Binding(
                                get: { viewModel.remindAt ?? Date() },
                                set: { viewModel.remindAt = $0 }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
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
}
