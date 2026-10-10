import XCTest
@testable import Scribe

/// Keeping local task reminders in step on iPhone / iPad, and hiding the
/// Mac's mirrored time-block events on the iOS planner.
final class TaskReminderPlanningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ id: String, remindIn seconds: TimeInterval?, completed: Bool = false) -> TodoTask {
        TodoTask(id: id, title: "Task \(id)",
                 remindAt: seconds.map { now.addingTimeInterval($0) },
                 completedAt: completed ? now : nil)
    }

    func testDesiredKeepsFutureOpenRemindersSoonestFirst() {
        let tasks = [
            task("late", remindIn: 7_200),
            task("soon", remindIn: 60),
            task("past", remindIn: -60),
            task("none", remindIn: nil),
            task("done", remindIn: 120, completed: true),
        ]
        let desired = TaskReminderPlanning.desired(tasks, now: now)
        XCTAssertEqual(desired.map(\.taskId), ["soon", "late"])
        XCTAssertEqual(TaskReminderPlanning.desired(tasks, now: now, limit: 1).map(\.taskId), ["soon"])
    }

    func testChangesOnlyTouchWhatDiffers() {
        let a = TaskReminderPlanning.Entry(taskId: "a", fireAt: now, title: "A", body: "")
        let b = TaskReminderPlanning.Entry(taskId: "b", fireAt: now, title: "B", body: "")
        let bMoved = TaskReminderPlanning.Entry(taskId: "b", fireAt: now.addingTimeInterval(60), title: "B", body: "")
        let gone = TaskReminderPlanning.Entry(taskId: "gone", fireAt: now, title: "G", body: "")

        let changes = TaskReminderPlanning.changes(
            desired: [a, bMoved],
            scheduled: ["a": a, "b": b, "gone": gone],
            pendingTaskIds: ["stale", "a"]
        )
        XCTAssertEqual(changes.schedule, ["b"])
        XCTAssertEqual(changes.cancel, ["gone", "stale"])
    }

    func testTaskIdFromNotificationIdentifier() {
        XCTAssertEqual(TaskReminderPlanning.taskId(fromNotificationIdentifier: TaskReminderScheduler.identifier(for: "x1")), "x1")
        XCTAssertNil(TaskReminderPlanning.taskId(fromNotificationIdentifier: "scribe.calendar.reminder.e1@1"))
    }

    // MARK: - Mirrored planner events

    func testMirroredBlocksAreHidden() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9)) ?? now
        let scheduled = TodoTask(id: "t", title: " Write report ", dueAt: start, estimatedMinutes: 45)
        let mirror = CalendarEventInfo(id: "m", title: "Write report", start: start,
                                       end: start.addingTimeInterval(45 * 60))
        let meeting = CalendarEventInfo(id: "x", title: "Write report", start: start,
                                        end: start.addingTimeInterval(30 * 60))
        let other = CalendarEventInfo(id: "o", title: "Standup", start: start, end: start.addingTimeInterval(45 * 60))
        let hidden = PlannerMirroredEventFilter.hiddenEventIds(events: [mirror, meeting, other],
                                                               tasks: [scheduled], calendar: calendar)
        XCTAssertEqual(hidden, ["m"])
        XCTAssertTrue(PlannerMirroredEventFilter.hiddenEventIds(events: [mirror], tasks: [], calendar: calendar).isEmpty)
    }
}
