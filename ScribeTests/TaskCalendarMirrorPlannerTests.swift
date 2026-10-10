import XCTest
import GRDB
@testable import Scribe

/// Time blocking's pure create / update / delete decisions, plus the
/// `task_calendar_blocks` link table (migration `v26_task_calendar_blocks`).
final class TaskCalendarMirrorPlannerTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var cal: Calendar { Self.cal }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func configuration(enabled: Bool = true, calendarId: String? = "cal-work") -> TaskCalendarMirrorConfiguration {
        TaskCalendarMirrorConfiguration(isEnabled: enabled, calendarId: calendarId,
                                        windowStart: date(9), windowEnd: date(20))
    }

    private func task(_ id: String, title: String = "Write report", due: Date?, estimate: Int? = nil,
                      completedAt: Date? = nil, cancelledAt: Date? = nil) -> TodoTask {
        TodoTask(id: id, title: title, dueAt: due, completedAt: completedAt,
                 cancelledAt: cancelledAt, estimatedMinutes: estimate)
    }

    private func link(_ taskId: String, event: String, calendar: String = "cal-work",
                      start: Date, end: Date, title: String = "Write report") -> TaskCalendarBlockLink {
        TaskCalendarBlockLink(taskId: taskId, eventIdentifier: event, calendarId: calendar,
                              lastStart: start, lastEnd: end, lastTitle: title)
    }

    private func plan(tasks: [TodoTask], links: [TaskCalendarBlockLink], existing: Set<String>,
                      configuration: TaskCalendarMirrorConfiguration) -> [TaskCalendarMirrorAction] {
        TaskCalendarMirrorPlanner.plan(tasks: tasks, links: links, existingEventIds: existing,
                                       configuration: configuration, calendar: cal)
    }

    // MARK: - Drafts

    func testDraftUsesEstimateOrDefaultDuration() {
        let withEstimate = TaskCalendarMirrorPlanner.draft(for: task("a", due: date(10, 9), estimate: 45), calendar: cal)
        XCTAssertEqual(withEstimate?.end, date(10, 9, 45))
        let without = TaskCalendarMirrorPlanner.draft(for: task("b", due: date(10, 9)), calendar: cal)
        XCTAssertEqual(without?.end, date(10, 9, 30))
        let blank = TaskCalendarMirrorPlanner.draft(for: task("c", title: "  ", due: date(10, 9)), calendar: cal)
        XCTAssertEqual(blank?.title, TaskCalendarMirrorPlanner.untitledTitle)
    }

    func testNoDraftForDateOnlyOrFinishedTasks() {
        XCTAssertNil(TaskCalendarMirrorPlanner.draft(for: task("a", due: date(10)), calendar: cal))
        XCTAssertNil(TaskCalendarMirrorPlanner.draft(for: task("b", due: nil), calendar: cal))
        XCTAssertNil(TaskCalendarMirrorPlanner.draft(for: task("c", due: date(10, 9), completedAt: date(10, 8)), calendar: cal))
        XCTAssertNil(TaskCalendarMirrorPlanner.draft(for: task("d", due: date(10, 9), cancelledAt: date(10, 8)), calendar: cal))
    }

    // MARK: - Create

    func testCreatesBlocksForScheduledTasksInTheWindow() {
        let actions = plan(tasks: [
            task("b", due: date(11, 14)),
            task("a", due: date(10, 9), estimate: 60),
            task("old", due: date(2, 9)),        // before the window
            task("far", due: date(25, 9)),       // after the window
            task("dateOnly", due: date(10)),
        ], links: [], existing: [], configuration: configuration())

        XCTAssertEqual(actions, [
            .create(TaskCalendarBlockDraft(taskId: "a", title: "Write report", start: date(10, 9), end: date(10, 10))),
            .create(TaskCalendarBlockDraft(taskId: "b", title: "Write report", start: date(11, 14), end: date(11, 14, 30))),
        ])
    }

    func testNothingWhenUnchanged() {
        let existing = link("a", event: "ev-a", start: date(10, 9), end: date(10, 9, 30))
        let actions = plan(tasks: [task("a", due: date(10, 9))], links: [existing],
                           existing: ["ev-a"], configuration: configuration())
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Update

    func testUpdatesWhenTimeDurationOrTitleChanges() {
        let existing = link("a", event: "ev-a", start: date(10, 9), end: date(10, 9, 30))
        let moved = plan(tasks: [task("a", due: date(10, 11), estimate: 45)], links: [existing],
                         existing: ["ev-a"], configuration: configuration())
        XCTAssertEqual(moved, [.update(existing, TaskCalendarBlockDraft(taskId: "a", title: "Write report",
                                                                        start: date(10, 11), end: date(10, 11, 45)))])

        let renamed = plan(tasks: [task("a", title: "Draft report", due: date(10, 9))], links: [existing],
                           existing: ["ev-a"], configuration: configuration())
        XCTAssertEqual(renamed, [.update(existing, TaskCalendarBlockDraft(taskId: "a", title: "Draft report",
                                                                          start: date(10, 9), end: date(10, 9, 30)))])
    }

    func testLinkedBlockOutsideTheWindowKeepsBeingUpdated() {
        let existing = link("a", event: "ev-a", start: date(2, 9), end: date(2, 9, 30))
        let actions = plan(tasks: [task("a", due: date(3, 9))], links: [existing],
                           existing: ["ev-a"], configuration: configuration())
        XCTAssertEqual(actions, [.update(existing, TaskCalendarBlockDraft(taskId: "a", title: "Write report",
                                                                          start: date(3, 9), end: date(3, 9, 30)))])
    }

    // MARK: - Delete

    func testDeletesWhenTaskCompletesIsUnscheduledOrDeleted() {
        let done = link("done", event: "ev-done", start: date(10, 9), end: date(10, 9, 30))
        let dateOnly = link("dateOnly", event: "ev-date", start: date(10, 9), end: date(10, 9, 30))
        let gone = link("gone", event: "ev-gone", start: date(10, 9), end: date(10, 9, 30))
        let actions = plan(
            tasks: [
                task("done", due: date(10, 9), completedAt: date(10, 9, 20)),
                task("dateOnly", due: date(10)),
            ],
            links: [gone, done, dateOnly],
            existing: ["ev-done", "ev-date", "ev-gone"],
            configuration: configuration()
        )
        XCTAssertEqual(actions, [.delete(dateOnly), .delete(done), .delete(gone)])
    }

    func testMissingEventIsForgottenNotDeleted() {
        let gone = link("gone", event: "ev-gone", start: date(10, 9), end: date(10, 9, 30))
        let actions = plan(tasks: [], links: [gone], existing: [], configuration: configuration())
        XCTAssertEqual(actions, [.forget(gone)])
    }

    func testEventRemovedInCalendarComesBackWhileTaskIsScheduled() {
        let stale = link("a", event: "ev-a", start: date(10, 9), end: date(10, 9, 30))
        let actions = plan(tasks: [task("a", due: date(10, 9))], links: [stale],
                           existing: [], configuration: configuration())
        XCTAssertEqual(actions, [
            .forget(stale),
            .create(TaskCalendarBlockDraft(taskId: "a", title: "Write report", start: date(10, 9), end: date(10, 9, 30))),
        ])
    }

    func testTurningOffRemovesOnlyScribesEvents() {
        let a = link("a", event: "ev-a", start: date(10, 9), end: date(10, 9, 30))
        let b = link("b", event: "ev-b", start: date(10, 11), end: date(10, 11, 30))
        let tasks = [task("a", due: date(10, 9)), task("b", due: date(10, 11)), task("c", due: date(10, 13))]

        let off = plan(tasks: tasks, links: [b, a], existing: ["ev-a"], configuration: configuration(enabled: false))
        XCTAssertEqual(off, [.delete(a), .forget(b)])

        let noCalendar = plan(tasks: tasks, links: [a], existing: ["ev-a"], configuration: configuration(calendarId: nil))
        XCTAssertEqual(noCalendar, [.delete(a)])
    }

    func testChangingTheCalendarMovesBlocks() {
        let old = link("a", event: "ev-a", calendar: "cal-home", start: date(10, 9), end: date(10, 9, 30))
        let actions = plan(tasks: [task("a", due: date(10, 9))], links: [old],
                           existing: ["ev-a"], configuration: configuration())
        XCTAssertEqual(actions, [
            .delete(old),
            .create(TaskCalendarBlockDraft(taskId: "a", title: "Write report", start: date(10, 9), end: date(10, 9, 30))),
        ])
    }

    func testOnlyLinkedEventsAreEverTouched() {
        // Events Scribe didn't create never appear in `links`, so no action
        // can name them — even when their identifiers are "existing".
        let mine = link("a", event: "ev-a", start: date(10, 9), end: date(10, 9, 30))
        let actions = plan(tasks: [task("a", due: date(10, 10)), task("b", due: date(10, 12))],
                           links: [mine], existing: ["ev-a", "someone-elses-event"],
                           configuration: configuration(enabled: false))
        for action in actions {
            switch action {
            case .create:
                XCTFail("Disabled mirroring must not create events")
            case .update(let link, _), .delete(let link), .forget(let link):
                XCTAssertEqual(link.eventIdentifier, "ev-a")
            }
        }
    }

    func testDefaultWindowSpansYesterdayToSixtyDaysAhead() {
        let window = TaskCalendarMirrorConfiguration.window(around: date(10, 15), calendar: cal)
        XCTAssertEqual(window.start, date(9))
        XCTAssertEqual(window.end, cal.date(byAdding: .day, value: 60, to: date(10)))
    }

    // MARK: - Link store + migration

    func testMigrationCreatesLinkTable() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        try dbm.database.read { db in
            XCTAssertTrue(try db.tableExists("task_calendar_blocks"))
            let columns = Set(try db.columns(in: "task_calendar_blocks").map(\.name))
            XCTAssertEqual(columns, ["taskId", "eventIdentifier", "calendarId", "lastStart", "lastEnd", "lastTitle"])
            let applied = try DatabaseManager.makeMigrator().appliedMigrations(db)
            XCTAssertTrue(applied.contains("v26_task_calendar_blocks"))
        }
    }

    func testLinkStoreUpsertAndDelete() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let store = TaskCalendarBlockLinkStore(databaseManager: dbm)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try store.upsert(link("t1", event: "e1", start: start, end: start.addingTimeInterval(1_800)))
        try store.upsert(link("t1", event: "e2", start: start, end: start.addingTimeInterval(3_600), title: "Moved"))
        XCTAssertEqual(try store.fetchAllLinks().map(\.eventIdentifier), ["e2"])
        XCTAssertEqual(try store.link(forTaskId: "t1")?.lastTitle, "Moved")

        // Another task claiming the same event takes it over (unique index).
        try store.upsert(link("t2", event: "e2", start: start, end: start.addingTimeInterval(1_800)))
        XCTAssertEqual(try store.fetchAllLinks().map(\.taskId), ["t2"])
        XCTAssertEqual(try store.mirroredEventIdentifiers(), ["e2"])

        try store.deleteLink(taskId: "t2")
        XCTAssertTrue(try store.fetchAllLinks().isEmpty)
    }
}
