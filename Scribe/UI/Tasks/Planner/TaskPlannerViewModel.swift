import Combine
import EventKit
import Foundation

/// State + actions for the planner's day time grid (TaskCalendarView's Day
/// mode): the day's calendar events, its scheduled task blocks, and the side
/// list of tasks still waiting for a time. Every write registers Edit › Undo.
@MainActor
final class TaskPlannerViewModel: ObservableObject {

    // MARK: - Published

    /// Open tasks (the planner's whole input set).
    @Published private(set) var tasks: [TodoTask] = []
    /// Events overlapping the shown day (timed and all-day).
    @Published private(set) var events: [CalendarEventInfo] = []
    /// Identifiers of events Scribe wrote as time blocks (hidden from the
    /// grid — the task block itself is drawn instead).
    @Published private(set) var mirroredEventIds: Set<String> = []
    @Published private(set) var day: Date

    weak var undoManager: UndoManager?

    let calendar = Calendar.current

    // MARK: - Private

    private let store: TaskStore
    private let reminderScheduler: TaskReminderScheduling
    private var taskCancellable: AnyCancellable?
    private var eventObserver: NSObjectProtocol?
    /// Own EventKit reader, created only while the calendar integration is
    /// active (no permission prompt from here).
    private var calendarStore: CalendarStore?

    init(store: TaskStore, reminderScheduler: TaskReminderScheduling) {
        self.store = store
        self.reminderScheduler = reminderScheduler
        self.day = Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Lifecycle

    func start() {
        if taskCancellable == nil {
            taskCancellable = store.observeTasks(filter: .all)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] tasks in
                          guard let self else { return }
                          self.tasks = tasks
                          self.reloadMirroredIds()
                      })
        }
        if eventObserver == nil {
            eventObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadEvents() }
            }
        }
        reloadEvents()
    }

    func stop() {
        taskCancellable?.cancel()
        taskCancellable = nil
        if let eventObserver {
            NotificationCenter.default.removeObserver(eventObserver)
            self.eventObserver = nil
        }
    }

    func show(day newDay: Date) {
        let normalized = calendar.startOfDay(for: newDay)
        guard normalized != day else { return }
        day = normalized
        reloadEvents()
    }

    /// Whether calendar events can be shown (integration on + full access).
    var showsCalendarEvents: Bool { CalendarService.shared.isActive }

    func reloadEvents() {
        reloadMirroredIds()
        guard CalendarService.shared.isActive else {
            calendarStore = nil
            if !events.isEmpty { events = [] }
            return
        }
        let reader: CalendarStore
        if let calendarStore {
            reader = calendarStore
        } else {
            reader = CalendarStore()
            calendarStore = reader
        }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        events = reader.events(from: start, to: end)
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    private func reloadMirroredIds() {
        let ids = TaskCalendarMirrorService.shared.mirroredEventIdentifiers()
        if ids != mirroredEventIds { mirroredEventIds = ids }
    }

    // MARK: - Derived

    var gridItems: [PlannerGridItem] {
        PlannerGrid.items(events: events, hiddenEventIds: mirroredEventIds,
                          tasks: tasks, day: day, calendar: calendar)
    }

    var allDayEvents: [CalendarEventInfo] {
        PlannerGrid.allDayEvents(events, day: day, calendar: calendar)
    }

    var sideList: PlannerSideList {
        PlannerScheduling.sideList(tasks, for: day, calendar: calendar, now: Date())
    }

    func task(id: String) -> TodoTask? {
        if let local = tasks.first(where: { $0.id == id }) { return local }
        return try? store.fetchTask(id: id)
    }

    // MARK: - Actions

    /// Gives `taskId` a time block starting at `startMinute` of the shown day
    /// (from a side-list drop, or the "Schedule at" menu).
    func schedule(taskId: String, startMinute: Int, snapMinutes: Int) {
        guard let task = task(id: taskId), PlannerScheduling.isOpen(task) else { return }
        let minute = PlannerScheduling.representableStartMinute(startMinute, snapMinutes: snapMinutes)
        let start = TimeGridGeometry.date(atMinute: minute, on: day, calendar: calendar)
        let wasScheduled = PlannerScheduling.isScheduled(task, calendar: calendar)
        write(PlannerScheduling.scheduling(task, at: start, calendar: calendar),
              before: task,
              actionName: wasScheduled ? "Move Time Block" : "Schedule Task")
    }

    /// Moves a block to start at `startMinute` of the shown day.
    func move(taskId: String, toStartMinute startMinute: Int, snapMinutes: Int) {
        guard let task = task(id: taskId) else { return }
        let minute = PlannerScheduling.representableStartMinute(startMinute, snapMinutes: snapMinutes)
        let start = TimeGridGeometry.date(atMinute: minute, on: day, calendar: calendar)
        guard task.dueAt != start else { return }
        write(PlannerScheduling.scheduling(task, at: start, calendar: calendar),
              before: task, actionName: "Move Time Block")
    }

    /// Changes a block's length.
    func resize(taskId: String, toMinutes minutes: Int) {
        guard let task = task(id: taskId) else { return }
        guard PlannerScheduling.durationMinutes(of: task) != minutes else { return }
        write(PlannerScheduling.resizing(task, toMinutes: minutes),
              before: task, actionName: "Resize Time Block")
    }

    /// Takes a task off the grid (keeps its date).
    func unschedule(taskId: String) {
        guard let task = task(id: taskId), PlannerScheduling.isScheduled(task, calendar: calendar) else { return }
        write(PlannerScheduling.unscheduling(task, calendar: calendar),
              before: task, actionName: "Remove Time")
    }

    func toggleCompleted(_ task: TodoTask) {
        do {
            if task.isCompleted {
                try store.uncompleteTask(id: task.id)
            } else {
                try store.completeTask(id: task.id)
            }
            if let stored = try store.fetchTask(id: task.id) {
                Self.refreshReminder(for: stored, scheduler: reminderScheduler)
            }
        } catch {
            Log.ui.error("TaskPlannerViewModel.toggleCompleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ updated: TodoTask, before: TodoTask, actionName: String) {
        guard updated != before else { return }
        do {
            try store.updateTask(updated)
        } catch {
            Log.ui.error("TaskPlannerViewModel write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let after = (try? store.fetchTask(id: before.id)) ?? updated
        Self.refreshReminder(for: after, scheduler: reminderScheduler)

        guard let undoManager else { return }
        let store = self.store
        let scheduler = reminderScheduler
        UndoableActions.register(
            on: undoManager,
            actionName: actionName,
            undo: { TaskPlannerViewModel.applySnapshot(before, store: store, scheduler: scheduler) },
            redo: { TaskPlannerViewModel.applySnapshot(after, store: store, scheduler: scheduler) }
        )
    }

    /// Copies the planner's fields from `snapshot` onto the stored row.
    private static func applySnapshot(_ snapshot: TodoTask, store: TaskStore, scheduler: TaskReminderScheduling) {
        do {
            guard let current = try store.fetchTask(id: snapshot.id) else { return }
            let restored = PlannerScheduling.restoring(from: snapshot, to: current)
            guard restored != current else { return }
            try store.updateTask(restored)
            if let stored = try store.fetchTask(id: snapshot.id) {
                refreshReminder(for: stored, scheduler: scheduler)
            }
        } catch {
            Log.ui.error("Planner undo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func refreshReminder(for task: TodoTask, scheduler: TaskReminderScheduling) {
        if task.isCompleted || task.isCancelled {
            let id = task.id
            Task { await scheduler.cancel(taskId: id) }
        } else {
            Task { await scheduler.schedule(task) }
        }
    }
}
