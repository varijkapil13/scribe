import Combine
import Foundation
import SwiftUI

/// iOS Tasks surface — a live, grouped task list over the shared `TaskStore`,
/// with a quick-add field that understands the same `#tag +project !priority`
/// + natural-date syntax as the Mac (via `QuickAddParser`).
struct TasksScreen: View {
    @StateObject private var model = TasksViewModel()
    @FocusState private var quickAddFocused: Bool
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.tasks) { task in
                            NavigationLink(value: task.id) {
                                TaskRow(task: task) { model.complete(task) }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { model.delete(task) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { model.complete(task) } label: {
                                    Label("Done", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { if model.isEmpty { emptyState } }
            .navigationTitle("Tasks")
            .navigationDestination(for: String.self) { TaskDetailScreen(taskId: $0) }
            .safeAreaInset(edge: .bottom) { quickAdd }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No tasks",
            systemImage: "checklist",
            description: Text("Add one below — try “draft deck tomorrow 5pm #work !high”.")
        )
    }

    private var quickAdd: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            TextField("Add a task…", text: $model.draft)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .focused($quickAddFocused)
                .onSubmit { model.addFromDraft(); quickAddFocused = true }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct TaskRow: View {
    let task: TodoTask
    let onComplete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                if let due = task.dueAt {
                    Text(due, format: .dateTime.weekday().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(isOverdue(due) ? Color.red : .secondary)
                }
            }
            Spacer(minLength: 0)
            if let p = task.priority {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(priorityColor(p))
                    .accessibilityLabel("\(p.rawValue) priority")
            }
        }
        .contentShape(Rectangle())
    }

    private func isOverdue(_ date: Date) -> Bool {
        date < Calendar.current.startOfDay(for: Date())
    }

    private func priorityColor(_ p: TodoTask.Priority) -> Color {
        switch p {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }
}

// MARK: - View model

@MainActor
final class TasksViewModel: ObservableObject {

    struct Section: Identifiable {
        let id: String
        let title: String
        let tasks: [TodoTask]
    }

    @Published private(set) var sections: [Section] = []
    @Published var draft: String = ""

    var isEmpty: Bool { sections.isEmpty }

    private let store: TaskStore
    private var cancellable: AnyCancellable?

    init(store: TaskStore = .shared) {
        self.store = store
        cancellable = store.observeTasks(filter: .all)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] tasks in
                self?.sections = Self.group(tasks)
            })
    }

    func addFromDraft() {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let parsed = QuickAddParser.parse(raw)
        let title = parsed.title.isEmpty ? raw : parsed.title
        _ = try? store.createTask(
            title: title,
            priority: parsed.priority,
            dueAt: parsed.dueAt,
            tags: parsed.tags
        )
        draft = ""
    }

    func complete(_ task: TodoTask) {
        try? store.completeTask(id: task.id)
    }

    func delete(_ task: TodoTask) {
        try? store.deleteTask(id: task.id)
    }

    /// Buckets incomplete tasks into Overdue / Today / Upcoming / No date —
    /// the same mental model as the Mac, flattened for a single-column phone.
    private static func group(_ tasks: [TodoTask]) -> [Section] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart) else { return [] }

        var overdue: [TodoTask] = []
        var today: [TodoTask] = []
        var upcoming: [TodoTask] = []
        var noDate: [TodoTask] = []

        for task in tasks {
            guard let due = task.dueAt else { noDate.append(task); continue }
            if due < todayStart { overdue.append(task) }
            else if due < tomorrowStart { today.append(task) }
            else { upcoming.append(task) }
        }

        var sections: [Section] = []
        if !overdue.isEmpty { sections.append(Section(id: "overdue", title: "Overdue", tasks: overdue)) }
        if !today.isEmpty { sections.append(Section(id: "today", title: "Today", tasks: today)) }
        if !upcoming.isEmpty { sections.append(Section(id: "upcoming", title: "Upcoming", tasks: upcoming)) }
        if !noDate.isEmpty { sections.append(Section(id: "nodate", title: "No date", tasks: noDate)) }
        return sections
    }
}
