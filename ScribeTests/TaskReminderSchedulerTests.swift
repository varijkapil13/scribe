import XCTest
import UserNotifications
@testable import Scribe

final class TaskReminderSchedulerTests: XCTestCase {

    // MARK: - Pure helpers

    func testIdentifierIsStable() {
        XCTAssertEqual(TaskReminderScheduler.identifier(for: "abc"), "scribe.task.abc")
    }

    func testShouldScheduleRequiresFutureRemindAndIncomplete() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = TodoTask(title: "p", remindAt: now.addingTimeInterval(-60))
        let future = TodoTask(title: "f", remindAt: now.addingTimeInterval(60))
        let none = TodoTask(title: "n")
        let done = TodoTask(title: "d", remindAt: now.addingTimeInterval(60), completedAt: now)

        XCTAssertFalse(TaskReminderScheduler.shouldSchedule(past, now: now))
        XCTAssertTrue(TaskReminderScheduler.shouldSchedule(future, now: now))
        XCTAssertFalse(TaskReminderScheduler.shouldSchedule(none, now: now))
        XCTAssertFalse(TaskReminderScheduler.shouldSchedule(done, now: now))
    }

    func testTriggerComponentsCarriesEverySegment() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let task = TodoTask(title: "t", remindAt: now.addingTimeInterval(3_600))
        let comps = try XCTUnwrap(TaskReminderScheduler.triggerComponents(for: task, now: now))
        // Year/month/day/hour/minute/second all populated; nothing else.
        XCTAssertNotNil(comps.year)
        XCTAssertNotNil(comps.month)
        XCTAssertNotNil(comps.day)
        XCTAssertNotNil(comps.hour)
        XCTAssertNotNil(comps.minute)
        XCTAssertNotNil(comps.second)
    }

    func testSnoozeDateIsExactlyFifteenMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            TaskReminderScheduler.snoozeDate(from: now).timeIntervalSince1970,
            15 * 60
        )
    }

    // MARK: - Scheduling against a fake adapter

    @MainActor
    func testScheduleAddsRequestForFutureTask() async {
        let fake = FakeNotificationCenter(grantAuth: true)
        let scheduler = TaskReminderScheduler(center: fake)
        let task = TodoTask(title: "Buy milk", remindAt: Date().addingTimeInterval(600))

        await scheduler.schedule(task)

        XCTAssertEqual(fake.added.map(\.identifier), [TaskReminderScheduler.identifier(for: task.id)])
        XCTAssertEqual(fake.added.first?.title, "Buy milk")
        XCTAssertTrue(fake.removed.isEmpty)
    }

    @MainActor
    func testScheduleRemovesPendingForCompletedOrPastTask() async {
        let fake = FakeNotificationCenter(grantAuth: true)
        let scheduler = TaskReminderScheduler(center: fake)
        let pastTask = TodoTask(title: "Old", remindAt: Date().addingTimeInterval(-60))

        await scheduler.schedule(pastTask)

        XCTAssertTrue(fake.added.isEmpty)
        XCTAssertEqual(fake.removed, [TaskReminderScheduler.identifier(for: pastTask.id)])
    }

    @MainActor
    func testCancelRemovesPending() async {
        let fake = FakeNotificationCenter(grantAuth: true)
        let scheduler = TaskReminderScheduler(center: fake)
        await scheduler.cancel(taskId: "abc")
        XCTAssertEqual(fake.removed, ["scribe.task.abc"])
    }

    @MainActor
    func testScheduleSkipsWhenAuthorizationDenied() async {
        let fake = FakeNotificationCenter(grantAuth: false)
        let scheduler = TaskReminderScheduler(center: fake)
        let task = TodoTask(title: "x", remindAt: Date().addingTimeInterval(60))

        await scheduler.schedule(task)

        XCTAssertTrue(fake.added.isEmpty)
        XCTAssertEqual(fake.authRequests, 1)
    }

    @MainActor
    func testHandleMarkDoneCompletesTaskAndCancels() async throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let task = try store.createTask(title: "Reply", remindAt: Date().addingTimeInterval(60))

        let fake = FakeNotificationCenter(grantAuth: true)
        let scheduler = TaskReminderScheduler(center: fake)
        scheduler.taskStore = store

        await scheduler.handle(actionId: TaskReminderScheduler.actionMarkDone, taskId: task.id)

        let refreshed = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNotNil(refreshed.completedAt)
        XCTAssertEqual(fake.removed.last, TaskReminderScheduler.identifier(for: task.id))
    }

    @MainActor
    func testHandleSnoozePushesRemindAtForwardAndReschedules() async throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let originalRemind = Date().addingTimeInterval(60)
        let task = try store.createTask(title: "Reply", remindAt: originalRemind)

        let fake = FakeNotificationCenter(grantAuth: true)
        let scheduler = TaskReminderScheduler(center: fake)
        scheduler.taskStore = store

        await scheduler.handle(actionId: TaskReminderScheduler.actionSnooze, taskId: task.id)

        let refreshed = try XCTUnwrap(store.fetchTask(id: task.id))
        let snoozed = try XCTUnwrap(refreshed.remindAt)
        // Snooze pushed remindAt at least ~14 minutes into the future.
        XCTAssertGreaterThan(snoozed.timeIntervalSinceNow, 14 * 60)
        // A new request was added for the snoozed time.
        XCTAssertEqual(fake.added.last?.identifier, TaskReminderScheduler.identifier(for: task.id))
    }
}

// MARK: - Fake adapter

/// Tests drive the fake from a single @MainActor context, so plain mutable
/// state is fine — `@unchecked Sendable` satisfies the protocol bound.
private final class FakeNotificationCenter: UNUserNotificationCenterAdapter, @unchecked Sendable {
    var grantAuth: Bool
    var authRequests = 0
    var added: [ReminderRequestPayload] = []
    var removed: [String] = []
    var categories: Set<UNNotificationCategory> = []

    init(grantAuth: Bool) { self.grantAuth = grantAuth }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authRequests += 1
        return grantAuth
    }
    func add(payload: ReminderRequestPayload) async throws {
        added.append(payload)
    }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) async {
        removed.append(contentsOf: ids)
    }
}
