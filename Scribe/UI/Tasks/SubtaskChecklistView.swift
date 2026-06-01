import SwiftUI
import Combine

/// Live checklist of a task's subtasks (TickTick parity). Observes the
/// `task_subtasks` table so edits from anywhere stay in sync; add/toggle/
/// rename/delete go straight through `TaskStore`.
@MainActor
final class SubtaskChecklistModel: ObservableObject {
    @Published private(set) var subtasks: [TaskSubtask] = []

    let taskId: String
    private let store: TaskStore
    private var cancellable: AnyCancellable?

    init(taskId: String, store: TaskStore = .shared) {
        self.taskId = taskId
        self.store = store
    }

    func start() {
        subtasks = (try? store.subtasks(for: taskId)) ?? []
        cancellable = store.observeSubtasks(taskId: taskId)
            .replaceError(with: [])
            .sink { [weak self] in self?.subtasks = $0 }
    }

    func stop() { cancellable = nil }

    var progress: SubtaskProgress {
        SubtaskProgress(completed: subtasks.filter(\.isCompleted).count, total: subtasks.count)
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? store.addSubtask(to: taskId, title: trimmed)
    }

    func toggle(_ subtask: TaskSubtask) {
        try? store.setSubtaskCompleted(id: subtask.id, isCompleted: !subtask.isCompleted)
    }

    func rename(_ subtask: TaskSubtask, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != subtask.title else { return }
        try? store.renameSubtask(id: subtask.id, title: trimmed)
    }

    func delete(_ subtask: TaskSubtask) {
        try? store.deleteSubtask(id: subtask.id)
    }
}

struct SubtaskChecklistView: View {
    @StateObject private var model: SubtaskChecklistModel
    @State private var newTitle = ""
    @FocusState private var addFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(taskId: String) {
        _model = StateObject(wrappedValue: SubtaskChecklistModel(taskId: taskId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.subtasks) { subtask in
                SubtaskRow(
                    subtask: subtask,
                    onToggle: {
                        withAnimation(DesignTokens.Motion.resolve(DesignTokens.Motion.snappy, reduceMotion: reduceMotion)) {
                            model.toggle(subtask)
                        }
                    },
                    onRename: { model.rename(subtask, to: $0) },
                    onDelete: { model.delete(subtask) }
                )
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                TextField("Add subtask", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($addFieldFocused)
                    .onSubmit {
                        model.add(newTitle)
                        newTitle = ""
                        addFieldFocused = true   // keep focus for rapid entry
                    }
            }
            .padding(.vertical, 3)
            .accessibilityLabel("Add subtask")
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// One checklist row: a toggle, an in-place editable title, and a hover-/
/// focus-revealed delete. Fully keyboard- and VoiceOver-operable.
private struct SubtaskRow: View {
    let subtask: TaskSubtask
    var onToggle: () -> Void
    var onRename: (String) -> Void
    var onDelete: () -> Void

    @State private var title: String
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    init(subtask: TaskSubtask, onToggle: @escaping () -> Void,
         onRename: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.subtask = subtask
        self.onToggle = onToggle
        self.onRename = onRename
        self.onDelete = onDelete
        _title = State(initialValue: subtask.title)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: onToggle) {
                Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(subtask.isCompleted ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subtask.isCompleted ? "Mark incomplete" : "Mark complete")

            TextField("Subtask", text: $title)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($fieldFocused)
                .strikethrough(subtask.isCompleted)
                .foregroundStyle(subtask.isCompleted ? .secondary : .primary)
                .onSubmit { onRename(title) }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { onRename(title) }
                }

            if hovering || fieldFocused {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete subtask")
            }
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
        // Keep the local field in sync if the row's title changes externally
        // (e.g. another device) while we aren't editing it.
        .onChange(of: subtask.title) { _, newValue in
            if !fieldFocused { title = newValue }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(subtask.isCompleted ? "Completed" : "")
    }
}
