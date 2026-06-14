import Combine
import Foundation
import SwiftUI

/// iOS Today surface — today's tasks (the `.today` filter already folds in
/// overdue) plus quick access to today's daily note. The Mac's side-by-side
/// `HSplitView` is replaced by a single-column layout suited to the phone;
/// iPad refinement can come later.
struct TodayScreen: View {
    @StateObject private var model = TodayViewModel()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    // Resolve/create today's daily note on tap (not in body).
                    Button {
                        let id = model.dailyNoteId()
                        if !id.isEmpty { path.append(id) }
                    } label: {
                        Label("Open today's note", systemImage: "sun.max")
                    }
                }

                Section("Tasks") {
                    if model.tasks.isEmpty {
                        Text("Nothing due today.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.tasks) { task in
                            HStack(spacing: 12) {
                                Button { model.complete(task) } label: {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                Text(task.title).strikethrough(task.isCompleted)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Self.todayTitle)
            .navigationDestination(for: String.self) { NoteEditorScreen(noteId: $0) }
        }
    }

    private static var todayTitle: String {
        Date().formatted(.dateTime.weekday(.wide).month().day())
    }
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var tasks: [TodoTask] = []

    private let tasksStore: TaskStore
    private let noteStore: NoteStore
    private var cancellable: AnyCancellable?

    init(tasksStore: TaskStore = .shared, noteStore: NoteStore = .shared) {
        self.tasksStore = tasksStore
        self.noteStore = noteStore
        cancellable = tasksStore.observeTasks(filter: .today)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.tasks = $0 })
    }

    func complete(_ task: TodoTask) {
        try? tasksStore.completeTask(id: task.id)
    }

    /// Resolves (creating if needed) today's daily note and returns its id for
    /// the editor `NavigationLink`.
    func dailyNoteId() -> String {
        (try? noteStore.dailyNote(for: Date()))?.id ?? ""
    }
}
