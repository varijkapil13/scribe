import XCTest
@testable import Scribe

/// Pure planning rules for the two-way Apple Reminders sync.
final class RemindersSyncPlannerTests: XCTestCase {

    // MARK: - Fixtures

    static let inboxList = "list-inbox"
    static let workList = "list-work"
    static let otherList = "list-other"

    static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Last-sync moment recorded in links.
    let synced = Date(timeIntervalSince1970: 1_800_000_000)
    var before: Date { synced.addingTimeInterval(-3_600) }
    var later: Date { synced.addingTimeInterval(600) }
    var muchLater: Date { synced.addingTimeInterval(1_200) }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Self.cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func task(
        _ id: String,
        _ title: String,
        project: String? = nil,
        notes: String = "",
        priority: TodoTask.Priority? = nil,
        due: Date? = nil,
        rule: String? = nil,
        completedAt: Date? = nil,
        cancelledAt: Date? = nil,
        updatedAt: Date
    ) -> TodoTask {
        TodoTask(
            id: id,
            title: title,
            notes: notes,
            projectId: project,
            priority: priority,
            dueAt: due,
            recurrenceRule: rule,
            completedAt: completedAt,
            createdAt: before,
            updatedAt: updatedAt,
            cancelledAt: cancelledAt
        )
    }

    private func reminder(
        _ id: String,
        _ title: String,
        list: String = RemindersSyncPlannerTests.inboxList,
        notes: String = "",
        due: RemindersSyncDue? = nil,
        priority: Int = 0,
        completed: Bool = false,
        completionDate: Date? = nil,
        rule: String? = nil,
        unsupported: Bool = false,
        external: String? = nil,
        modified: Date
    ) -> RemindersSyncReminder {
        RemindersSyncReminder(
            calendarItemIdentifier: id,
            externalIdentifier: external,
            listId: list,
            title: title,
            notes: notes,
            due: due,
            priority: priority,
            isCompleted: completed,
            completionDate: completionDate,
            recurrenceRule: rule,
            hasUnsupportedRecurrence: unsupported,
            lastModifiedAt: modified,
            creationDate: before
        )
    }

    private func link(_ taskId: String, _ reminderId: String, external: String? = nil) -> TaskReminderLink {
        TaskReminderLink(
            taskId: taskId,
            calendarItemIdentifier: reminderId,
            externalIdentifier: external,
            lastSyncedTaskUpdatedAt: synced,
            lastSyncedReminderModifiedAt: synced
        )
    }

    private var inboxOnly: RemindersListMapping {
        RemindersListMapping(inboxListId: Self.inboxList)
    }

    private var inboxAndWork: RemindersListMapping {
        RemindersListMapping(inboxListId: Self.inboxList, projectToList: ["p-work": Self.workList])
    }

    private func plan(
        tasks: [TodoTask] = [],
        reminders: [RemindersSyncReminder] = [],
        links: [TaskReminderLink] = [],
        mapping: RemindersListMapping? = nil,
        direction: RemindersSyncDirection = .twoWay,
        complete: Bool = true
    ) -> RemindersSyncPlan {
        RemindersSyncPlanner.plan(
            RemindersSyncPlanInput(
                tasks: tasks,
                reminders: reminders,
                links: links,
                mapping: mapping ?? inboxOnly,
                direction: direction,
                reminderSnapshotIsComplete: complete
            ),
            calendar: Self.cal
        )
    }

    private func hasDelete(_ plan: RemindersSyncPlan) -> Bool {
        plan.actions.contains { action in
            switch action {
            case .deleteTask, .deleteReminder: return true
            default: return false
            }
        }
    }

    // MARK: - First sync (no links)

    func testFirstSyncExportsOpenInboxTasksAndImportsOpenInboxReminders() {
        let open = task("t-open", "Write report", notes: "draft", priority: .medium, updatedAt: before)
        let done = task("t-done", "Old thing", completedAt: before, updatedAt: before)
        let unmapped = task("t-proj", "Project task", project: "p-unmapped", updatedAt: before)
        let rOpen = reminder("r-open", "Call mom", notes: "Sunday", priority: 9, modified: before)
        let rDone = reminder("r-done", "Finished", completed: true, completionDate: before, modified: before)
        let rOther = reminder("r-other", "Elsewhere", list: Self.otherList, modified: before)

        let result = plan(tasks: [open, done, unmapped], reminders: [rOpen, rDone, rOther])

        XCTAssertEqual(result.actions, [
            .createReminder(
                taskId: "t-open",
                listId: Self.inboxList,
                fields: RemindersSyncFields(title: "Write report", notes: "draft", due: nil, priority: 5, recurrenceRule: nil),
                isCompleted: false,
                completionDate: nil
            ),
            .createTask(
                calendarItemIdentifier: "r-open",
                changes: RemindersSyncTaskChanges(title: "Call mom", notes: "Sunday", dueAt: nil, priority: .low, recurrenceRule: nil, projectId: nil),
                isCompleted: false
            ),
        ])
        XCTAssertFalse(hasDelete(result))
    }

    func testFirstSyncPairsByTitleAndDueInsteadOfDuplicating() {
        let due = day(2026, 10, 12)
        let t = task("t1", "Buy milk", priority: .high, due: due, updatedAt: before)
        let r = reminder("r1", "  buy MILK ", notes: "2%",
                         due: RemindersSyncDue(date: due, hasTime: false), modified: before)

        let result = plan(tasks: [t], reminders: [r])

        XCTAssertEqual(result.actions.first, .link(taskId: "t1", calendarItemIdentifier: "r1"))
        XCTAssertFalse(result.actions.contains { if case .createReminder = $0 { return true }; return false })
        XCTAssertFalse(result.actions.contains { if case .createTask = $0 { return true }; return false })
        // Empty fields are filled from the other side; nothing is overwritten.
        XCTAssertTrue(result.actions.contains(.updateTask(
            taskId: "t1",
            calendarItemIdentifier: "r1",
            changes: RemindersSyncTaskChanges(title: "Buy milk", notes: "2%", dueAt: due, priority: .high, recurrenceRule: nil, projectId: nil)
        )))
        XCTAssertTrue(result.actions.contains(.updateReminder(
            calendarItemIdentifier: "r1",
            taskId: "t1",
            moveToListId: nil,
            fields: RemindersSyncFields(title: "  buy MILK ", notes: "2%", due: RemindersSyncDue(date: due, hasTime: false), priority: 1, recurrenceRule: nil),
            includeRecurrence: false
        )))
        XCTAssertFalse(hasDelete(result))
    }

    func testFirstSyncPairingNeverOverwritesExistingContent() {
        let t = task("t1", "Plan trip", notes: "mine", priority: .low, updatedAt: before)
        let r = reminder("r1", "Plan trip", notes: "theirs", priority: 1, modified: later)

        let result = plan(tasks: [t], reminders: [r])

        XCTAssertEqual(result.actions, [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testFirstSyncMatchesTimedDueToTheMinute() {
        let due = day(2026, 10, 12, 9, 30)
        let t = task("t1", "Standup", due: due, updatedAt: before)
        let r = reminder("r1", "Standup", due: RemindersSyncDue(date: due.addingTimeInterval(20), hasTime: true), modified: before)

        XCTAssertEqual(plan(tasks: [t], reminders: [r]).actions, [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testFirstSyncDifferentDueDatesAreNotPaired() {
        let t = task("t1", "Dentist", due: day(2026, 10, 12), updatedAt: before)
        let r = reminder("r1", "Dentist", due: RemindersSyncDue(date: day(2026, 10, 13), hasTime: false), modified: before)

        let actions = plan(tasks: [t], reminders: [r]).actions
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.contains { if case .createReminder("t1", _, _, _, _) = $0 { return true }; return false })
        XCTAssertTrue(actions.contains { if case .createTask("r1", _, _) = $0 { return true }; return false })
    }

    func testFirstSyncPairsDuplicatesOneToOne() {
        let t1 = task("t1", "Water plants", updatedAt: before)
        let t2 = task("t2", "Water plants", updatedAt: before)
        let r1 = reminder("r1", "Water plants", modified: before)

        let actions = plan(tasks: [t1, t2], reminders: [r1]).actions
        XCTAssertEqual(actions.first, .link(taskId: "t1", calendarItemIdentifier: "r1"))
        XCTAssertTrue(actions.contains { if case .createReminder("t2", _, _, _, _) = $0 { return true }; return false })
        XCTAssertEqual(actions.count, 2)
    }

    func testFirstSyncWithNoListsMappedDoesNothing() {
        let t = task("t1", "Anything", updatedAt: before)
        let r = reminder("r1", "Anything else", modified: before)
        let result = plan(tasks: [t], reminders: [r], mapping: RemindersListMapping(inboxListId: nil))
        XCTAssertEqual(result.actions, [])
    }

    func testFirstSyncImportsIntoMappedProject() {
        let r = reminder("r1", "Ship it", list: Self.workList, modified: before)
        let actions = plan(reminders: [r], mapping: inboxAndWork).actions
        XCTAssertEqual(actions, [
            .createTask(
                calendarItemIdentifier: "r1",
                changes: RemindersSyncTaskChanges(title: "Ship it", notes: "", dueAt: nil, priority: nil, recurrenceRule: nil, projectId: "p-work"),
                isCompleted: false
            ),
        ])
    }

    func testUntitledRemindersAreNotImported() {
        let r = reminder("r1", "   ", modified: before)
        XCTAssertEqual(plan(reminders: [r]).actions, [])
    }

    // MARK: - Linked pairs: last writer wins

    func testUnchangedPairDoesNothing() {
        let t = task("t1", "Same", updatedAt: synced)
        let r = reminder("r1", "Same", modified: synced)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [])
    }

    func testStampsWithinToleranceCountAsUnchanged() {
        let t = task("t1", "Mine", updatedAt: synced.addingTimeInterval(0.4))
        let r = reminder("r1", "Theirs", modified: synced.addingTimeInterval(0.0004))
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [])
    }

    func testTaskStampMovingBackwardsStillCountsAsChange() {
        // CloudKit sync writes a remote edit with its original, older stamp.
        let t = task("t1", "Edited on iPhone", updatedAt: before)
        let r = reminder("r1", "Original", modified: synced)
        guard case .updateReminder(_, _, _, let fields, _) =
                plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions.first else {
            return XCTFail("expected the task edit to be pushed")
        }
        XCTAssertEqual(fields.title, "Edited on iPhone")
    }

    func testTaskEditIsPushedToReminder() {
        let due = day(2026, 11, 1, 14, 0)
        let t = task("t1", "New title", notes: "n", priority: .high, due: due, updatedAt: later)
        let r = reminder("r1", "Old title", modified: synced)

        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [
            .updateReminder(
                calendarItemIdentifier: "r1",
                taskId: "t1",
                moveToListId: nil,
                fields: RemindersSyncFields(title: "New title", notes: "n", due: RemindersSyncDue(date: due, hasTime: true), priority: 1, recurrenceRule: nil),
                includeRecurrence: true
            ),
        ])
    }

    func testReminderEditIsPulledIntoTask() {
        let t = task("t1", "Old", notes: "keep?", priority: .low, updatedAt: synced)
        let r = reminder("r1", "New", notes: "", due: RemindersSyncDue(date: day(2026, 10, 20), hasTime: false), priority: 5, modified: later)

        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [
            .updateTask(
                taskId: "t1",
                calendarItemIdentifier: "r1",
                changes: RemindersSyncTaskChanges(title: "New", notes: "", dueAt: day(2026, 10, 20), priority: .medium, recurrenceRule: nil, projectId: nil)
            ),
        ])
    }

    func testConflictNewerReminderWins() {
        let t = task("t1", "Task side", updatedAt: later)
        let r = reminder("r1", "Reminder side", modified: muchLater)

        let actions = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions
        XCTAssertEqual(actions.count, 1)
        guard case .updateTask(_, _, let changes) = actions.first else {
            return XCTFail("expected the reminder to win, got \(actions)")
        }
        XCTAssertEqual(changes.title, "Reminder side")
    }

    func testConflictNewerTaskWins() {
        let t = task("t1", "Task side", updatedAt: muchLater)
        let r = reminder("r1", "Reminder side", modified: later)

        let actions = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions
        XCTAssertEqual(actions.count, 1)
        guard case .updateReminder(_, _, _, let fields, _) = actions.first else {
            return XCTFail("expected the task to win, got \(actions)")
        }
        XCTAssertEqual(fields.title, "Task side")
    }

    func testChangedButEqualRefreshesLinkOnly() {
        // e.g. a tag edit bumped updatedAt without touching synced fields.
        let t = task("t1", "Same", updatedAt: later)
        let r = reminder("r1", "Same", modified: synced)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions,
                       [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testPriorityInSameBucketIsNotChurned() {
        // EventKit 3 is "high" — same as the task's; only the title changed.
        let t = task("t1", "Old", priority: .high, updatedAt: synced)
        let r = reminder("r1", "New", priority: 3, modified: later)

        guard case .updateTask(_, _, let changes) = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions.first else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(changes.priority, .high)
    }

    func testDateOnlyDueEqualsMidnightTaskDue() {
        let t = task("t1", "X", due: day(2026, 10, 12), updatedAt: synced)
        let r = reminder("r1", "X", due: RemindersSyncDue(date: day(2026, 10, 12), hasTime: false), modified: later)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions,
                       [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    // MARK: - Completion

    func testCompletingTaskCompletesReminder() {
        let doneAt = later
        let t = task("t1", "X", completedAt: doneAt, updatedAt: later)
        let r = reminder("r1", "X", modified: synced)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [
            .setReminderCompletion(calendarItemIdentifier: "r1", taskId: "t1", isCompleted: true, completionDate: doneAt),
        ])
    }

    func testCancellingTaskCompletesReminder() {
        let t = task("t1", "X", cancelledAt: later, updatedAt: later)
        let r = reminder("r1", "X", modified: synced)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [
            .setReminderCompletion(calendarItemIdentifier: "r1", taskId: "t1", isCompleted: true, completionDate: later),
        ])
    }

    func testCompletingReminderCompletesTask() {
        let t = task("t1", "X", updatedAt: synced)
        let r = reminder("r1", "X", completed: true, completionDate: later, modified: later)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [
            .setTaskCompletion(taskId: "t1", calendarItemIdentifier: "r1", isCompleted: true, completionDate: later),
        ])
    }

    func testReopeningReminderReopensTask() {
        let t = task("t1", "X", completedAt: before, updatedAt: synced)
        let r = reminder("r1", "X", completed: false, modified: later)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions, [
            .setTaskCompletion(taskId: "t1", calendarItemIdentifier: "r1", isCompleted: false, completionDate: nil),
        ])
    }

    // MARK: - Deletes (tombstone-safe)

    func testReminderDeletedRemovesUnchangedTask() {
        let t = task("t1", "X", updatedAt: synced)
        let result = plan(tasks: [t, task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")])
        XCTAssertEqual(result.actions, [.deleteTask(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testReminderDeletedButTaskEditedRecreatesReminder() {
        let t = task("t1", "Edited", updatedAt: later)
        let result = plan(tasks: [t, task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")])
        XCTAssertEqual(result.actions, [
            .createReminder(
                taskId: "t1",
                listId: Self.inboxList,
                fields: RemindersSyncFields(title: "Edited", notes: "", due: nil, priority: 0, recurrenceRule: nil),
                isCompleted: false,
                completionDate: nil
            ),
        ])
    }

    func testTaskDeletedRemovesUnchangedReminder() {
        let result = plan(tasks: [task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r1", "X", modified: synced), reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")])
        XCTAssertEqual(result.actions, [.deleteReminder(calendarItemIdentifier: "r1", taskId: "t1")])
    }

    func testTaskDeletedButReminderEditedRecreatesTask() {
        let result = plan(tasks: [task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r1", "Edited", modified: later), reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")])
        XCTAssertEqual(result.actions, [
            .createTask(
                calendarItemIdentifier: "r1",
                changes: RemindersSyncTaskChanges(title: "Edited", notes: "", dueAt: nil, priority: nil, recurrenceRule: nil, projectId: nil),
                isCompleted: false
            ),
        ])
    }

    func testClearedCompletedReminderKeepsFinishedTask() {
        // "Clear Completed" in Reminders must not erase Scribe's history.
        let done = task("t1", "Done", completedAt: before, updatedAt: synced)
        let wontDo = task("t3", "Skipped", cancelledAt: before, updatedAt: synced)
        let result = plan(tasks: [done, task("t2", "Y", updatedAt: synced), wontDo],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2"), link("t3", "r3")])
        XCTAssertFalse(hasDelete(result))
        XCTAssertEqual(result.actions, [.unlink(taskId: "t1"), .unlink(taskId: "t3")])
    }

    func testBothSidesGoneDropsLink() {
        let result = plan(tasks: [task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")])
        XCTAssertEqual(result.actions, [.unlink(taskId: "t1")])
    }

    func testItemsWithoutLinksAreNeverDeleted() {
        // A reminder that simply isn't there (never linked) doesn't delete the
        // task; it gets exported instead.
        let result = plan(tasks: [task("t1", "Lonely", updatedAt: synced)], reminders: [])
        XCTAssertFalse(hasDelete(result))
        XCTAssertEqual(result.actions.count, 1)
    }

    func testMassReminderDisappearanceIsHeldBack() {
        var tasks: [TodoTask] = []
        var links: [TaskReminderLink] = []
        for i in 0..<8 {
            tasks.append(task("t\(i)", "Item \(i)", updatedAt: synced))
            links.append(link("t\(i)", "r\(i)"))
        }
        // Only one reminder survives: 7 of 8 linked tasks would be deleted.
        let result = plan(tasks: tasks, reminders: [reminder("r0", "Item 0", modified: synced)], links: links)
        XCTAssertFalse(hasDelete(result))
        XCTAssertEqual(result.suppressedTaskDeletes.count, 7)
    }

    func testEmptyReminderSnapshotNeverDeletesTasks() {
        let result = plan(tasks: [task("t1", "X", updatedAt: synced)], reminders: [], links: [link("t1", "r1")])
        XCTAssertFalse(hasDelete(result))
        XCTAssertEqual(result.suppressedTaskDeletes, ["t1"])
    }

    func testIncompleteSnapshotNeverDeletesTasks() {
        let result = plan(tasks: [task("t1", "X", updatedAt: synced), task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")],
                          complete: false)
        XCTAssertFalse(hasDelete(result))
        XCTAssertEqual(result.suppressedTaskDeletes, ["t1"])
    }

    func testSmallDeleteBatchAmongManyLinksGoesThrough() {
        var tasks: [TodoTask] = []
        var reminders: [RemindersSyncReminder] = []
        var links: [TaskReminderLink] = []
        for i in 0..<20 {
            tasks.append(task("t\(i)", "Item \(i)", updatedAt: synced))
            if i >= 2 { reminders.append(reminder("r\(i)", "Item \(i)", modified: synced)) }
            links.append(link("t\(i)", "r\(i)"))
        }
        let result = plan(tasks: tasks, reminders: reminders, links: links)
        XCTAssertEqual(result.actions, [
            .deleteTask(taskId: "t0", calendarItemIdentifier: "r0"),
            .deleteTask(taskId: "t1", calendarItemIdentifier: "r1"),
        ])
        XCTAssertTrue(result.suppressedTaskDeletes.isEmpty)
    }

    func testDeleteSafetyLimit() {
        XCTAssertFalse(RemindersSyncPlanner.exceedsDeleteSafetyLimit(deletes: 5, linkCount: 5))
        XCTAssertTrue(RemindersSyncPlanner.exceedsDeleteSafetyLimit(deletes: 6, linkCount: 10))
        XCTAssertFalse(RemindersSyncPlanner.exceedsDeleteSafetyLimit(deletes: 6, linkCount: 100))
    }

    func testReminderFoundByExternalIdentifierIsRelinkedNotDeleted() {
        let t = task("t1", "X", updatedAt: synced)
        let r = reminder("r-new", "X", external: "ext-1", modified: synced)
        let result = plan(tasks: [t], reminders: [r], links: [link("t1", "r-old", external: "ext-1")])
        XCTAssertEqual(result.actions, [.link(taskId: "t1", calendarItemIdentifier: "r-new")])
    }

    func testAmbiguousExternalIdentifierLeavesPairAlone() {
        let t = task("t1", "X", updatedAt: synced)
        let a = reminder("r-a", "X", external: "dup", modified: synced)
        let b = reminder("r-b", "X", external: "dup", modified: synced)
        let result = plan(tasks: [t], reminders: [a, b], links: [link("t1", "r-old", external: "dup")])
        XCTAssertEqual(result.actions, [])
    }

    // MARK: - Direction

    func testImportOnlyNeverWritesReminders() {
        let t = task("t1", "Edited here", updatedAt: later)
        let r = reminder("r1", "Original", modified: synced)
        let fresh = task("t2", "New local", updatedAt: later)
        let result = plan(tasks: [t, fresh], reminders: [r], links: [link("t1", "r1")], direction: .importOnly)
        // The local edit is absorbed (link refreshed), nothing exported.
        XCTAssertEqual(result.actions, [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testImportOnlyKeepsReminderWhenTaskDeleted() {
        let result = plan(tasks: [], reminders: [reminder("r1", "X", modified: synced)],
                          links: [link("t1", "r1")], direction: .importOnly)
        XCTAssertEqual(result.actions, [])
    }

    func testImportOnlyDeletesTaskWhenReminderDeleted() {
        let result = plan(tasks: [task("t1", "X", updatedAt: synced), task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")], direction: .importOnly)
        XCTAssertEqual(result.actions, [.deleteTask(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testImportOnlyUnlinksEditedTaskWhoseReminderWasDeleted() {
        let result = plan(tasks: [task("t1", "Edited", updatedAt: later), task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")], direction: .importOnly)
        XCTAssertEqual(result.actions, [.unlink(taskId: "t1")])
    }

    func testExportOnlyNeverWritesTasks() {
        let t = task("t1", "Original", updatedAt: synced)
        let r = reminder("r1", "Edited there", modified: later)
        let fresh = reminder("r2", "New remote", modified: later)
        let result = plan(tasks: [t], reminders: [r, fresh], links: [link("t1", "r1")], direction: .exportOnly)
        XCTAssertEqual(result.actions, [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testExportOnlyNeverDeletesTasks() {
        let result = plan(tasks: [task("t1", "X", updatedAt: synced), task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")], direction: .exportOnly)
        XCTAssertEqual(result.actions, [])
    }

    func testExportOnlyDeletesReminderWhenTaskDeleted() {
        let result = plan(tasks: [task("t2", "Y", updatedAt: synced)],
                          reminders: [reminder("r1", "X", modified: synced), reminder("r2", "Y", modified: synced)],
                          links: [link("t1", "r1"), link("t2", "r2")], direction: .exportOnly)
        XCTAssertEqual(result.actions, [.deleteReminder(calendarItemIdentifier: "r1", taskId: "t1")])
    }

    // MARK: - Lists ↔ projects

    func testMovingTaskToMappedProjectMovesReminder() {
        let t = task("t1", "X", project: "p-work", updatedAt: later)
        let r = reminder("r1", "X", modified: synced)
        let actions = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")], mapping: inboxAndWork).actions
        guard case .updateReminder(_, _, let moveTo, _, _) = actions.first else {
            return XCTFail("expected a move, got \(actions)")
        }
        XCTAssertEqual(moveTo, Self.workList)
    }

    func testMovingReminderToMappedListMovesTask() {
        let t = task("t1", "X", updatedAt: synced)
        let r = reminder("r1", "X", list: Self.workList, modified: later)
        let actions = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")], mapping: inboxAndWork).actions
        guard case .updateTask(_, _, let changes) = actions.first else {
            return XCTFail("expected a task update, got \(actions)")
        }
        XCTAssertEqual(changes.projectId, "p-work")
    }

    func testReminderInUnmappedListKeepsTaskProject() {
        let t = task("t1", "Old", project: "p-work", updatedAt: synced)
        let r = reminder("r1", "New", list: Self.otherList, modified: later)
        let actions = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")], mapping: inboxAndWork).actions
        guard case .updateTask(_, _, let changes) = actions.first else {
            return XCTFail("expected a task update, got \(actions)")
        }
        XCTAssertEqual(changes.projectId, "p-work")
        XCTAssertEqual(changes.title, "New")
    }

    func testReminderEditDoesNotPullTaskOutOfUnmappedProject() {
        // The task was moved into an unmapped project in Scribe; its reminder
        // stayed in the Inbox list. Editing the reminder must not drag the
        // task back into the Inbox.
        let t = task("t1", "Old", project: "p-unmapped", updatedAt: synced)
        let r = reminder("r1", "New", list: Self.inboxList, modified: later)
        let actions = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")], mapping: inboxAndWork).actions
        guard case .updateTask(_, _, let changes) = actions.first else {
            return XCTFail("expected a task update, got \(actions)")
        }
        XCTAssertEqual(changes.projectId, "p-unmapped")
        XCTAssertEqual(changes.title, "New")
    }

    func testMappingResolvesProjectsByName() {
        let projects = [
            Project(id: "p1", name: "Work", sortOrder: 0),
            Project(id: "p2", name: "  café ", sortOrder: 1),
            Project(id: "p3", name: "work", sortOrder: 2),     // duplicate name: loses
            Project(id: "p4", name: "Inbox", sortOrder: 3),    // the Inbox list is never claimed
            Project(id: "p5", name: "No list", sortOrder: 4),
        ]
        let lists = [
            RemindersListInfo(id: "L-work", title: "WORK"),
            RemindersListInfo(id: "L-cafe", title: "Cafe"),
            RemindersListInfo(id: "L-inbox", title: "Inbox"),
        ]
        let mapping = RemindersListMapping.resolve(projects: projects, lists: lists, inboxListId: "L-inbox", mapProjectsByName: true)
        XCTAssertEqual(mapping.inboxListId, "L-inbox")
        XCTAssertEqual(mapping.listId(forProjectId: "p1"), "L-work")
        XCTAssertEqual(mapping.listId(forProjectId: "p2"), "L-cafe")
        XCTAssertNil(mapping.listId(forProjectId: "p3"))
        XCTAssertNil(mapping.listId(forProjectId: "p4"))
        XCTAssertNil(mapping.listId(forProjectId: "p5"))
        XCTAssertEqual(mapping.listId(forProjectId: nil), "L-inbox")
        XCTAssertEqual(mapping.projectTarget(forListId: "L-inbox"), .inbox)
        XCTAssertEqual(mapping.projectTarget(forListId: "L-work"), .project("p1"))
        XCTAssertNil(mapping.projectTarget(forListId: "L-unknown"))
    }

    func testMappingWithoutNameMatchingOrMissingInboxList() {
        let projects = [Project(id: "p1", name: "Work")]
        let lists = [RemindersListInfo(id: "L-work", title: "Work")]
        let off = RemindersListMapping.resolve(projects: projects, lists: lists, inboxListId: "L-work", mapProjectsByName: false)
        XCTAssertEqual(off.inboxListId, "L-work")
        XCTAssertNil(off.listId(forProjectId: "p1"))

        let missing = RemindersListMapping.resolve(projects: projects, lists: lists, inboxListId: "gone", mapProjectsByName: true)
        XCTAssertNil(missing.inboxListId)
        XCTAssertEqual(missing.listId(forProjectId: "p1"), "L-work")
    }

    // MARK: - Recurrence

    func testEquivalentRecurrenceIsNotChurned() {
        let t = task("t1", "Gym", due: day(2026, 10, 12), rule: "FREQ=WEEKLY;BYDAY=WE,MO", updatedAt: later)
        let r = reminder("r1", "Gym", due: RemindersSyncDue(date: day(2026, 10, 12), hasTime: false),
                         rule: "FREQ=WEEKLY;BYDAY=MO,WE", modified: synced)
        XCTAssertEqual(plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions,
                       [.link(taskId: "t1", calendarItemIdentifier: "r1")])
    }

    func testTaskRecurrenceIsPushed() {
        let due = day(2026, 10, 12)
        let t = task("t1", "Gym", due: due, rule: "FREQ=DAILY;INTERVAL=2", updatedAt: later)
        let r = reminder("r1", "Gym", due: RemindersSyncDue(date: due, hasTime: false), modified: synced)
        guard case .updateReminder(_, _, _, let fields, let includeRecurrence) =
                plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions.first else {
            return XCTFail("expected an update")
        }
        XCTAssertTrue(includeRecurrence)
        XCTAssertEqual(fields.recurrenceRule, "FREQ=DAILY;INTERVAL=2")
    }

    func testUnsupportedReminderRecurrenceIsLeftAlone() {
        let t = task("t1", "Renew", updatedAt: later)
        let r = reminder("r1", "Old", unsupported: true, modified: synced)
        guard case .updateReminder(_, _, _, _, let includeRecurrence) =
                plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions.first else {
            return XCTFail("expected an update")
        }
        XCTAssertFalse(includeRecurrence)
    }

    func testPulledRecurrenceWithoutDueIsDropped() {
        let t = task("t1", "Old", updatedAt: synced)
        let r = reminder("r1", "New", rule: "FREQ=DAILY", modified: later)
        guard case .updateTask(_, _, let changes) = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions.first else {
            return XCTFail("expected an update")
        }
        XCTAssertNil(changes.recurrenceRule)
    }

    func testPulledRecurrenceWithDueIsApplied() {
        let due = day(2026, 10, 12)
        let t = task("t1", "Old", due: due, updatedAt: synced)
        let r = reminder("r1", "Old", due: RemindersSyncDue(date: due, hasTime: false), rule: "FREQ=MONTHLY;BYDAY=-1FR", modified: later)
        guard case .updateTask(_, _, let changes) = plan(tasks: [t], reminders: [r], links: [link("t1", "r1")]).actions.first else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(changes.recurrenceRule, "FREQ=MONTHLY;BYDAY=-1FR")
    }
}

/// Field conversions (priority, due dates, recurrence descriptors).
final class RemindersFieldMappingTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        return calendar
    }()

    func testPriorityFromReminders() {
        XCTAssertNil(RemindersFieldMapping.scribePriority(fromReminderPriority: 0))
        XCTAssertEqual(RemindersFieldMapping.scribePriority(fromReminderPriority: 1), .high)
        XCTAssertEqual(RemindersFieldMapping.scribePriority(fromReminderPriority: 4), .high)
        XCTAssertEqual(RemindersFieldMapping.scribePriority(fromReminderPriority: 5), .medium)
        XCTAssertEqual(RemindersFieldMapping.scribePriority(fromReminderPriority: 6), .low)
        XCTAssertEqual(RemindersFieldMapping.scribePriority(fromReminderPriority: 9), .low)
        XCTAssertNil(RemindersFieldMapping.scribePriority(fromReminderPriority: 42))
    }

    func testPriorityToReminders() {
        XCTAssertEqual(RemindersFieldMapping.reminderPriority(from: .high), 1)
        XCTAssertEqual(RemindersFieldMapping.reminderPriority(from: .medium), 5)
        XCTAssertEqual(RemindersFieldMapping.reminderPriority(from: .low), 9)
        XCTAssertEqual(RemindersFieldMapping.reminderPriority(from: nil), 0)
    }

    func testDueDateOnlyVersusDateTime() {
        let cal = Self.cal
        let midnight = cal.date(from: DateComponents(year: 2026, month: 3, day: 4))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 15))!

        XCTAssertEqual(RemindersFieldMapping.due(fromTaskDueAt: midnight, calendar: cal),
                       RemindersSyncDue(date: midnight, hasTime: false))
        XCTAssertEqual(RemindersFieldMapping.due(fromTaskDueAt: morning, calendar: cal),
                       RemindersSyncDue(date: morning, hasTime: true))
        XCTAssertNil(RemindersFieldMapping.due(fromTaskDueAt: nil, calendar: cal))

        // A date-only reminder lands on local midnight even if its date is mid-day.
        XCTAssertEqual(RemindersFieldMapping.taskDueAt(from: RemindersSyncDue(date: morning, hasTime: false), calendar: cal), midnight)
        XCTAssertEqual(RemindersFieldMapping.taskDueAt(from: RemindersSyncDue(date: morning, hasTime: true), calendar: cal), morning)

        XCTAssertTrue(RemindersFieldMapping.dueEqual(RemindersSyncDue(date: midnight, hasTime: false),
                                                     RemindersSyncDue(date: morning, hasTime: false), calendar: cal))
        XCTAssertFalse(RemindersFieldMapping.dueEqual(RemindersSyncDue(date: midnight, hasTime: false),
                                                      RemindersSyncDue(date: morning, hasTime: true), calendar: cal))
        XCTAssertFalse(RemindersFieldMapping.dueEqual(nil, RemindersSyncDue(date: morning, hasTime: true), calendar: cal))
        XCTAssertTrue(RemindersFieldMapping.dueEqual(nil, nil, calendar: cal))
    }

    func testNormalizedRecurrence() {
        XCTAssertNil(RemindersFieldMapping.normalizedRecurrence(nil).rule)
        XCTAssertTrue(RemindersFieldMapping.normalizedRecurrence(nil).supported)
        XCTAssertEqual(RemindersFieldMapping.normalizedRecurrence("FREQ=WEEKLY;BYDAY=FR,MO").rule, "FREQ=WEEKLY;BYDAY=MO,FR")
        XCTAssertFalse(RemindersFieldMapping.normalizedRecurrence("FREQ=YEARLY").supported)
    }

    func testDescriptorToRRule() {
        XCTAssertEqual(RemindersRecurrenceDescriptor(frequency: .daily).rrule, "FREQ=DAILY")
        XCTAssertEqual(RemindersRecurrenceDescriptor(frequency: .daily, interval: 3).rrule, "FREQ=DAILY;INTERVAL=3")
        XCTAssertEqual(
            RemindersRecurrenceDescriptor(frequency: .weekly, daysOfWeek: [.init(weekday: 6), .init(weekday: 2)]).rrule,
            "FREQ=WEEKLY;BYDAY=MO,FR"
        )
        XCTAssertEqual(
            RemindersRecurrenceDescriptor(frequency: .monthly, interval: 2, daysOfWeek: [.init(weekday: 3, weekNumber: 2)]).rrule,
            "FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU"
        )
        XCTAssertEqual(RemindersRecurrenceDescriptor(frequency: .monthly).rrule, "FREQ=MONTHLY")
        // Not representable in Scribe.
        XCTAssertNil(RemindersRecurrenceDescriptor(frequency: .yearly).rrule)
        XCTAssertNil(RemindersRecurrenceDescriptor(frequency: .daily, hasEnd: true).rrule)
        XCTAssertNil(RemindersRecurrenceDescriptor(frequency: .monthly, hasOtherConstraints: true).rrule)
        XCTAssertNil(RemindersRecurrenceDescriptor(frequency: .weekly, daysOfWeek: [.init(weekday: 2, weekNumber: 1)]).rrule)
        XCTAssertNil(RemindersRecurrenceDescriptor(
            frequency: .monthly, daysOfWeek: [.init(weekday: 2, weekNumber: 1), .init(weekday: 3, weekNumber: 1)]
        ).rrule)
    }

    func testDescriptorRoundTripsScribeRules() {
        for rule in ["FREQ=DAILY", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR", "FREQ=MONTHLY;BYDAY=-1SU", "FREQ=MONTHLY;INTERVAL=3"] {
            let descriptor = RemindersRecurrenceDescriptor(rrule: rule)
            XCTAssertNotNil(descriptor, rule)
            XCTAssertEqual(descriptor?.rrule, rule)
        }
        XCTAssertNil(RemindersRecurrenceDescriptor(rrule: "garbage"))
    }

    func testTaskChangesApplyOnlySyncedFields() {
        let original = TodoTask(id: "t1", title: "A", notes: "n", projectId: "p", priority: .low,
                                dueAt: nil, remindAt: Date(timeIntervalSince1970: 5), sortOrder: 7, isPinned: true)
        let changes = RemindersSyncTaskChanges(title: "B", notes: "m", dueAt: nil, priority: .high, recurrenceRule: nil, projectId: nil)
        let updated = changes.applied(to: original)
        XCTAssertEqual(updated.title, "B")
        XCTAssertEqual(updated.notes, "m")
        XCTAssertEqual(updated.priority, .high)
        XCTAssertNil(updated.projectId)
        XCTAssertEqual(updated.remindAt, original.remindAt)
        XCTAssertEqual(updated.sortOrder, 7)
        XCTAssertTrue(updated.isPinned)
    }

    func testDirectionCapabilities() {
        XCTAssertTrue(RemindersSyncDirection.twoWay.writesTasks)
        XCTAssertTrue(RemindersSyncDirection.twoWay.writesReminders)
        XCTAssertFalse(RemindersSyncDirection.importOnly.writesReminders)
        XCTAssertTrue(RemindersSyncDirection.importOnly.writesTasks)
        XCTAssertFalse(RemindersSyncDirection.exportOnly.writesTasks)
        XCTAssertTrue(RemindersSyncDirection.exportOnly.writesReminders)
    }
}

/// The `task_reminder_links` table (migration `v21_reminders_link`).
final class TaskReminderLinkStoreTests: XCTestCase {

    private func makeStores() throws -> (TaskStore, TaskReminderLinkStore, DatabaseManager) {
        let dbm = try DatabaseManager(path: ":memory:")
        return (TaskStore(databaseManager: dbm), TaskReminderLinkStore(databaseManager: dbm), dbm)
    }

    func testMigrationCreatesTable() throws {
        let (_, _, dbm) = try makeStores()
        try dbm.database.read { db in
            XCTAssertTrue(try db.tableExists("task_reminder_links"))
            let columns = Set(try db.columns(in: "task_reminder_links").map(\.name))
            XCTAssertEqual(columns, [
                "taskId", "calendarItemIdentifier", "externalIdentifier",
                "lastSyncedTaskUpdatedAt", "lastSyncedReminderModifiedAt",
            ])
            let applied = try DatabaseManager.makeMigrator().appliedMigrations(db)
            XCTAssertTrue(applied.contains("v21_reminders_link"))
        }
    }

    func testUpsertReplacesAndStealsReminder() throws {
        let (_, links, _) = try makeStores()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try links.upsert(TaskReminderLink(taskId: "t1", calendarItemIdentifier: "r1", externalIdentifier: "e1",
                                          lastSyncedTaskUpdatedAt: stamp, lastSyncedReminderModifiedAt: stamp))
        try links.upsert(TaskReminderLink(taskId: "t1", calendarItemIdentifier: "r2"))
        XCTAssertEqual(try links.fetchAllLinks().map(\.calendarItemIdentifier), ["r2"])

        // Another task claiming r2 takes it over (one reminder ↔ one task).
        try links.upsert(TaskReminderLink(taskId: "t2", calendarItemIdentifier: "r2"))
        let all = try links.fetchAllLinks()
        XCTAssertEqual(all.map(\.taskId), ["t2"])

        try links.deleteLink(taskId: "t2")
        XCTAssertTrue(try links.fetchAllLinks().isEmpty)
    }

    func testStampsRoundTrip() throws {
        let (_, links, _) = try makeStores()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000.25)
        try links.upsert(TaskReminderLink(taskId: "t1", calendarItemIdentifier: "r1", externalIdentifier: "e1",
                                          lastSyncedTaskUpdatedAt: stamp, lastSyncedReminderModifiedAt: Date(timeIntervalSince1970: 0)))
        let stored = try XCTUnwrap(links.link(forTaskId: "t1"))
        XCTAssertEqual(stored.externalIdentifier, "e1")
        XCTAssertEqual(try XCTUnwrap(stored.lastSyncedTaskUpdatedAt).timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertEqual(stored.lastSyncedReminderModifiedAt, Date(timeIntervalSince1970: 0))
    }

    func testLinkOutlivesDeletedTask() throws {
        let (tasks, links, _) = try makeStores()
        let created = try tasks.createTask(title: "Doomed")
        let fetched = try links.fetchAllTasks()
        XCTAssertEqual(fetched.map(\.title), ["Doomed"])
        let taskId = try XCTUnwrap(fetched.first?.id)
        XCTAssertEqual(taskId, created.id)

        try links.upsert(TaskReminderLink(taskId: taskId, calendarItemIdentifier: "r1"))
        try tasks.deleteTask(id: taskId)

        // The link is the tombstone that lets the sync delete the reminder.
        XCTAssertEqual(try links.fetchAllLinks().map(\.taskId), [taskId])
        XCTAssertTrue(try links.fetchAllTasks().isEmpty)
    }

    func testFetchAllTasksIncludesCompleted() throws {
        let (tasks, links, _) = try makeStores()
        let open = try tasks.createTask(title: "Open")
        let done = try tasks.createTask(title: "Done")
        try tasks.completeTask(id: done.id)
        let ids = Set(try links.fetchAllTasks().map(\.id))
        XCTAssertEqual(ids, [open.id, done.id])
    }

    func testRemindersPaneIsListedUnderStorageAndSync() {
        XCTAssertEqual(SettingsPane.reminders.group, .storageSync)
        XCTAssertEqual(SettingsPane.reminders.title, "Reminders")
    }
}
