import Combine
import Foundation
import SwiftUI

/// iOS Today: today's calendar events and meetings (EventKit, opt-in), then
/// Overdue / Today / This Evening tasks (the same planning rules as the
/// Mac), plus quick access to today's daily note and a quick-add button.
struct TodayScreen: View {
    @StateObject private var library = TasksLibraryModel(store: TaskStore.shared)
    @StateObject private var model = TodayTasksModel(store: TaskStore.shared, noteStore: NoteStore.shared)
    @ObservedObject private var calendarEvents = TasksCalendarEventsModel.shared
    @State private var path = NavigationPath()
    @State private var events: [CalendarEventInfo] = []
    @State private var showQuickAdd = false

    private var actions: TaskMobileActions { .live }

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

                calendarSection

                if model.sections.isEmpty {
                    Section {
                        Label("Nothing due today", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.tasks) { task in
                            NavigationLink(value: TaskRouteID(id: task.id)) {
                                MobileTaskRow(
                                    task: task,
                                    projectName: library.project(task.projectId)?.name,
                                    tags: model.tagsByTask[task.id] ?? [],
                                    onToggle: { actions.toggleCompleted(task) }
                                )
                            }
                            .taskSwipeActions(task, actions: actions)
                            .contextMenu {
                                TaskRowContextMenu(task: task, projects: library.projects, actions: actions)
                            }
                        }
                    } header: {
                        HStack {
                            if section.kind == .evening {
                                Image(systemName: "moon.fill").foregroundStyle(.indigo)
                            }
                            Text(section.title)
                                .foregroundStyle(section.kind == .overdue ? Color.red : Color.secondary)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            actions.drop(tokens: items, ontoSection: section.kind)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Self.todayTitle)
            .navigationDestination(for: String.self) { noteId in dailyNoteDestination(noteId) }
            .navigationDestination(for: TaskRouteID.self) { route in TaskDetailScreen(taskId: route.id) }
            .overlay(alignment: .bottomTrailing) {
                TasksAddButton { showQuickAdd = true }
            }
            .sheet(isPresented: $showQuickAdd) {
                TaskQuickAddSheet(destination: .today, library: library)
            }
            .refreshable { reloadEvents() }
        }
        .onAppear {
            TasksIOSBootstrap.start()
            library.start()
            model.start()
            calendarEvents.refreshAccess()
            reloadEvents()
        }
        .onChange(of: calendarEvents.revision) { reloadEvents() }
        .onChange(of: calendarEvents.isGranted) { reloadEvents() }
    }

    @ViewBuilder
    private var calendarSection: some View {
        if calendarEvents.isActive {
            if !events.isEmpty {
                Section("Calendar") {
                    ForEach(events, id: \.self) { event in
                        TasksCalendarEventRow(event: event)
                    }
                }
            }
        } else {
            Section {
                TasksCalendarPromptRow(calendar: calendarEvents)
            }
        }
    }

    private func reloadEvents() {
        let now = Date()
        // Timed events that haven't ended yet, plus all-day ones.
        events = calendarEvents.events(on: now).filter { $0.isAllDay || $0.end > now }
    }

    /// The daily-note editor. Isolated here so a rename on the notes side is
    /// a one-line fix.
    @ViewBuilder
    private func dailyNoteDestination(_ noteId: String) -> some View {
        NoteEditorScreen(noteId: noteId)
    }

    private static var todayTitle: String {
        Date().formatted(.dateTime.weekday(.wide).month().day())
    }
}

/// Today's tasks in Overdue / Today / This Evening sections.
@MainActor
final class TodayTasksModel: ObservableObject {
    @Published private(set) var sections: [TaskListSection] = []
    @Published private(set) var tagsByTask: [String: [String]] = [:]

    private let store: TaskStore
    private let noteStore: NoteStore
    private var cancellable: AnyCancellable?

    init(store: TaskStore, noteStore: NoteStore) {
        self.store = store
        self.noteStore = noteStore
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = store.observeTasks(filter: .today)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] tasks in
                guard let self else { return }
                self.tagsByTask = (try? self.store.fetchTagsForTasks(tasks.map(\.id))) ?? [:]
                self.sections = TaskListSectioning.todaySections(tasks, calendar: .current, now: Date())
            })
    }

    /// Resolves (creating if needed) today's daily note and returns its id for
    /// the editor `NavigationLink`.
    func dailyNoteId() -> String {
        (try? noteStore.dailyNote(for: Date()))?.id ?? ""
    }
}
