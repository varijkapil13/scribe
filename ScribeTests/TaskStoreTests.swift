import XCTest
import GRDB
@testable import Scribe

/// Storage-layer tests for `TaskStore` — exercises the v3 migration and the
/// task / project / tag CRUD plus filter queries.
final class TaskStoreTests: XCTestCase {

    private var manager: DatabaseManager!
    private var store: TaskStore!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: ":memory:")
        store = TaskStore(databaseManager: manager)
    }

    override func tearDown() {
        store = nil
        manager = nil
    }

    // MARK: - Project CRUD

    func testCreateAndFetchProjects() throws {
        let work = try store.createProject(name: "Work", color: "#FF8800", icon: "briefcase")
        let personal = try store.createProject(name: "Personal")

        let projects = try store.fetchProjects()
        XCTAssertEqual(projects.map(\.id), [work.id, personal.id])
        XCTAssertEqual(projects.first?.color, "#FF8800")
    }

    func testDeleteProjectNullsTaskProjectId() throws {
        let project = try store.createProject(name: "Work")
        let task = try store.createTask(title: "Ship slice 1", projectId: project.id)
        try store.deleteProject(id: project.id)

        let refreshed = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(refreshed.projectId)
    }

    // MARK: - Task CRUD

    func testCreateTaskWithTagsRoundTrip() throws {
        let task = try store.createTask(
            title: "Buy milk",
            tags: ["Errands", "errands", " Shopping "]
        )
        XCTAssertEqual(task.title, "Buy milk")
        XCTAssertNil(task.completedAt)

        let tags = try store.tags(for: task.id)
        // Tags are normalised (lowercased + trimmed + de-duplicated).
        XCTAssertEqual(tags, ["errands", "shopping"])
    }

    func testCompleteAndUncompleteRecordsHistory() throws {
        let task = try store.createTask(title: "Take meds")
        try store.completeTask(id: task.id)
        let after = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNotNil(after.completedAt)

        try store.uncompleteTask(id: task.id)
        let undone = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(undone.completedAt)

        // History row from the first completion is preserved even after undo.
        let count = try manager.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_completions WHERE taskId = ?", arguments: [task.id])
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Filters

    func testInboxFilterReturnsOnlyProjectlessIncomplete() throws {
        let project = try store.createProject(name: "Work")
        _ = try store.createTask(title: "In project", projectId: project.id)
        let inboxTask = try store.createTask(title: "Loose end")
        let done = try store.createTask(title: "Was inbox")
        try store.completeTask(id: done.id)

        let inbox = try store.fetchTasks(filter: .inbox)
        XCTAssertEqual(inbox.map(\.id), [inboxTask.id])
    }

    func testTodayFilterIncludesOverdueAndDueToday() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 14))!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let later = cal.date(byAdding: .day, value: 3, to: now)!

        let overdue = try store.createTask(title: "Overdue", dueAt: yesterday)
        let today = try store.createTask(title: "Today", dueAt: now)
        _ = try store.createTask(title: "Future", dueAt: later)
        _ = try store.createTask(title: "Undated")

        let result = try store.fetchTasks(filter: .today, calendar: cal, now: now)
        XCTAssertEqual(Set(result.map(\.id)), [overdue.id, today.id])
    }

    func testUpcomingFilterCovers7DayWindowExcludingToday() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 9))!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        let inSixDays = cal.date(byAdding: .day, value: 6, to: now)!
        let inEightDays = cal.date(byAdding: .day, value: 8, to: now)!

        _ = try store.createTask(title: "Today", dueAt: now)
        let t1 = try store.createTask(title: "Tomorrow", dueAt: tomorrow)
        let t2 = try store.createTask(title: "+6", dueAt: inSixDays)
        _ = try store.createTask(title: "+8", dueAt: inEightDays)

        let result = try store.fetchTasks(filter: .upcoming, calendar: cal, now: now)
        XCTAssertEqual(Set(result.map(\.id)), [t1.id, t2.id])
    }

    func testProjectFilterAndCompletedFilter() throws {
        let project = try store.createProject(name: "Work")
        let live = try store.createTask(title: "Open", projectId: project.id)
        let done = try store.createTask(title: "Done", projectId: project.id)
        try store.completeTask(id: done.id)

        let open = try store.fetchTasks(filter: .project(project.id))
        XCTAssertEqual(open.map(\.id), [live.id])

        let completed = try store.fetchTasks(filter: .completed)
        XCTAssertEqual(completed.map(\.id), [done.id])
    }

    func testTagFilterUsesNormalisedValue() throws {
        let task = try store.createTask(title: "Email Bob", tags: ["Work"])
        _ = try store.createTask(title: "Walk dog", tags: ["personal"])

        let work = try store.fetchTasks(filter: .tag("work"))
        XCTAssertEqual(work.map(\.id), [task.id])
    }

    // MARK: - Reordering

    func testReorderTasksPersistsNewSortOrder() throws {
        let a = try store.createTask(title: "A")
        let b = try store.createTask(title: "B")
        let c = try store.createTask(title: "C")

        try store.reorderTasks([c.id, a.id, b.id])

        let result = try store.fetchTasks(filter: .all)
        XCTAssertEqual(result.map(\.id), [c.id, a.id, b.id])
    }

    func testReorderTasksIgnoresTasksOutsideScope() throws {
        // Inbox tasks.
        let i1 = try store.createTask(title: "Inbox 1")
        let i2 = try store.createTask(title: "Inbox 2")
        // Project tasks.
        let project = try store.createProject(name: "Work")
        let p1 = try store.createTask(title: "Proj 1", projectId: project.id)
        let p2 = try store.createTask(title: "Proj 2", projectId: project.id)

        // Try to reorder a project task within the Inbox scope — must be a
        // no-op for that task.
        let inboxScope: String? = nil
        try store.reorderTasks([i2.id, p1.id, i1.id], in: inboxScope)

        let inbox = try store.fetchTasks(filter: .inbox)
        XCTAssertEqual(inbox.map(\.id), [i2.id, i1.id])

        let proj = try store.fetchTasks(filter: .project(project.id))
        // Project ordering untouched.
        XCTAssertEqual(proj.map(\.id), [p1.id, p2.id])
    }

    // MARK: - Sort order

    func testCompletedTasksSortNewestFirst() throws {
        let cal = Calendar(identifier: .gregorian)
        let t0 = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let t1 = cal.date(from: DateComponents(year: 2026, month: 5, day: 3))!

        let oldDone = try store.createTask(title: "Old done")
        let newDone = try store.createTask(title: "New done")
        try store.completeTask(id: oldDone.id, at: t0)
        try store.completeTask(id: newDone.id, at: t1)

        let completed = try store.fetchTasks(filter: .completed)
        XCTAssertEqual(completed.map(\.id), [newDone.id, oldDone.id])
    }

    // MARK: - Tag filter edge cases

    func testTagFilterReturnsEmptyForUnknownTag() throws {
        _ = try store.createTask(title: "Tagged", tags: ["work"])
        let result = try store.fetchTasks(filter: .tag("nonexistent"))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Recurrence

    func testCreateRecurringTaskWithoutDueDateThrows() throws {
        XCTAssertThrowsError(
            try store.createTask(title: "Daily standup", recurrenceRule: "FREQ=DAILY")
        ) { error in
            guard case TaskStoreError.recurringTaskRequiresDueDate = error else {
                XCTFail("Expected TaskStoreError.recurringTaskRequiresDueDate, got \(error)")
                return
            }
        }
    }

    func testUpdateTaskAddingRecurrenceWithoutDueDateThrows() throws {
        var task = try store.createTask(title: "No due date task")
        task.recurrenceRule = "FREQ=WEEKLY"
        XCTAssertThrowsError(try store.updateTask(task)) { error in
            guard case TaskStoreError.recurringTaskRequiresDueDate = error else {
                XCTFail("Expected TaskStoreError.recurringTaskRequiresDueDate, got \(error)")
                return
            }
        }
    }

    func testCompleteRecurringTaskAdvancesDueDateAndClearsCompletedAt() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = try store.createTask(
            title: "Daily standup",
            dueAt: due,
            recurrenceRule: "FREQ=DAILY"
        )
        try store.completeTask(id: task.id, at: due)

        let updated = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(updated.completedAt)
        let expectedDue = Calendar.utcCalendar.date(byAdding: .day, value: 1, to: due)!
        XCTAssertEqual(updated.dueAt, expectedDue)
    }

    func testCompleteRecurringTaskInsertsHistoryRow() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = try store.createTask(
            title: "Weekly review",
            dueAt: due,
            recurrenceRule: "FREQ=WEEKLY"
        )
        try store.completeTask(id: task.id, at: due)

        let count = try manager.database.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM task_completions WHERE taskId = ?",
                arguments: [task.id])
        }
        XCTAssertEqual(count, 1)
    }

    func testCreateTaskWithMalformedRuleThrows() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(
            try store.createTask(title: "Bad rule", dueAt: due, recurrenceRule: "FREQ=YEARLY")
        ) { error in
            guard case RecurrenceError.invalidRule = error else {
                XCTFail("Expected RecurrenceError.invalidRule, got \(error)")
                return
            }
        }
    }

    func testUpdateTaskWithMalformedRuleThrows() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        var task = try store.createTask(title: "Good task", dueAt: due, recurrenceRule: "FREQ=DAILY")
        task.recurrenceRule = "NOT_A_RULE"
        XCTAssertThrowsError(try store.updateTask(task)) { error in
            guard case RecurrenceError.invalidRule = error else {
                XCTFail("Expected RecurrenceError.invalidRule, got \(error)")
                return
            }
        }
    }

    // MARK: - Project moves & reorder

    func testMoveTaskAssignsNewProjectAndAppendsToScope() throws {
        let work = try store.createProject(name: "Work")
        // Existing task already in the destination so we can verify ordering.
        let existing = try store.createTask(title: "In work", projectId: work.id)
        let inboxTask = try store.createTask(title: "Inbox task")

        try store.moveTask(id: inboxTask.id, toProject: work.id)

        let workTasks = try store.fetchTasks(filter: .project(work.id))
        XCTAssertEqual(workTasks.map(\.id), [existing.id, inboxTask.id])

        let inbox = try store.fetchTasks(filter: .inbox)
        XCTAssertTrue(inbox.isEmpty)
    }

    func testMoveTaskBackToInboxClearsProjectId() throws {
        let project = try store.createProject(name: "Work")
        let task = try store.createTask(title: "Move me", projectId: project.id)

        try store.moveTask(id: task.id, toProject: nil)

        let refreshed = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(refreshed.projectId)
    }

    func testReorderProjectsUpdatesSortOrder() throws {
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        let c = try store.createProject(name: "C")

        try store.reorderProjects([c.id, a.id, b.id])

        let result = try store.fetchProjects()
        XCTAssertEqual(result.map(\.id), [c.id, a.id, b.id])
    }

    // MARK: - Source links

    func testTaskCanLinkToSessionAndActionItem() throws {
        // Create the referenced session and action item rows first so the
        // foreign-key constraints are satisfied.
        let transcripts = TranscriptStore(databaseManager: manager)
        let session = try transcripts.createSession(title: "Standup")
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "ok",
            keyDecisions: [],
            actionItems: [
                ActionItem(
                    id: UUID(),
                    description: "Follow up with Bob",
                    assignee: nil,
                    deadline: nil,
                    priority: nil,
                    sourceText: ""
                )
            ],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try transcripts.saveSummary(summary)
        let actionItemId = summary.actionItems[0].id.uuidString

        let task = try store.createTask(
            title: "Follow up with Bob",
            sourceSessionId: session.id,
            sourceActionItemId: actionItemId
        )
        let fetched = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertEqual(fetched.sourceSessionId, session.id)
        XCTAssertEqual(fetched.sourceActionItemId, actionItemId)
    }
}
