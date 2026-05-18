import Combine
import Foundation
import SwiftUI

@MainActor
final class TaskCalendarViewModel: ObservableObject {

    // MARK: - Published

    /// Tasks keyed by "yyyy-MM-dd". Includes all non-completed tasks that have a due date.
    @Published private(set) var tasksByDay: [String: [TodoTask]] = [:]
    /// Date keys ("yyyy-MM-dd") that have a daily note.
    @Published private(set) var datesWithNotes: Set<String> = []
    @Published var displayMonth: Date
    @Published var selectedDay: Date?

    // MARK: - Properties

    let cal = Calendar.current
    private let store: TaskStore
    private var taskCancellable: AnyCancellable?
    private var noteCancellable: AnyCancellable?

    // MARK: - Init

    init(store: TaskStore = TaskStore.shared) {
        self.store = store
        let today = Date()
        self.displayMonth = Calendar.current.startOfMonth(for: today)
        self.selectedDay  = Calendar.current.startOfDay(for: today)
    }

    // MARK: - Lifecycle

    func start() {
        taskCancellable = store.observeTasks(filter: .all)
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] tasks in
                guard let self else { return }
                self.tasksByDay = Dictionary(
                    grouping: tasks.filter { $0.dueAt != nil },
                    by: { Self.dayKey(for: $0.dueAt!) }
                )
            })

        noteCancellable = NoteStore.shared.observeNotes()
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] _ in
                guard let self else { return }
                self.reloadNoteDates()
            })
        reloadNoteDates()
    }

    func stop() {
        taskCancellable?.cancel()
        taskCancellable = nil
        noteCancellable?.cancel()
        noteCancellable = nil
    }

    // MARK: - Queries

    func tasks(for date: Date) -> [TodoTask] {
        tasksByDay[Self.dayKey(for: date)] ?? []
    }

    func hasNote(for date: Date) -> Bool {
        datesWithNotes.contains(Self.dayKey(for: date))
    }

    func existingDailyNote(for date: Date) -> Note? {
        try? NoteStore.shared.fetchExistingDailyNote(for: date)
    }

    var selectedDayTasks: [TodoTask] {
        selectedDay.map { tasks(for: $0) } ?? []
    }

    func totalCount(for date: Date) -> Int {
        tasks(for: date).count
    }

    // MARK: - Private

    private func reloadNoteDates() {
        datesWithNotes = Set((try? NoteStore.shared.fetchDailyDates()) ?? [])
    }

    // MARK: - Navigation

    func navigateMonth(by n: Int) {
        guard let next = cal.date(byAdding: .month, value: n, to: displayMonth)
        else { return }
        displayMonth = next
    }

    // MARK: - Grid building

    /// Re-exposed for view-side convenience. The grid math itself lives in
    /// `CalendarMonthGrid` so it's locale-aware and unit-testable.
    typealias CalendarCell = CalendarMonthGrid.LabelledCell

    func buildCells() -> [CalendarCell] {
        CalendarMonthGrid.labelledCells(forMonth: displayMonth, calendar: cal)
    }

    // MARK: - Actions

    func toggleCompleted(_ task: TodoTask) {
        do {
            if task.isCompleted {
                try store.uncompleteTask(id: task.id)
            } else {
                try store.completeTask(id: task.id)
            }
        } catch {
            Log.ui.error("TaskCalendarViewModel.toggleCompleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
