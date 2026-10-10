import XCTest
@testable import Scribe

/// Undo/redo support for task actions (`TaskUndoField`, `TaskUndo`, and the
/// `TaskListViewModel` registrations).
final class TaskUndoTests: XCTestCase {

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

    // MARK: - Pure field copy

    func testApplyingCopiesOnlyTheRequestedFields() {
        let due = Date(timeIntervalSince1970: 1_000)
        let snapshot = TodoTask(title: "Old title", priority: .high, dueAt: due)
        var current = snapshot
        current.title = "New title"
        current.priority = .low
        current.dueAt = nil
        current.completedAt = Date(timeIntervalSince1970: 2_000)

        let priorityOnly = TaskUndoField.applying([.priority], from: snapshot, to: current)
        XCTAssertEqual(priorityOnly.priority, .high)
        XCTAssertNil(priorityOnly.dueAt)
        XCTAssertEqual(priorityOnly.title, "New title", "Unrelated edits are kept")

        let completion = TaskUndoField.applying([.completion], from: snapshot, to: current)
        XCTAssertNil(completion.completedAt)
        XCTAssertEqual(completion.dueAt, due, "A recurring completion's due-date advance is reverted too")
        XCTAssertEqual(completion.priority, .low)

        let dueDate = TaskUndoField.applying([.dueDate], from: snapshot, to: current)
        XCTAssertEqual(dueDate.dueAt, due)
        XCTAssertNotNil(dueDate.completedAt)
    }

    // MARK: - Store round trips

    func testRestoreRevertsCompletion() throws {
        let task = try store.createTask(title: "Ship it")
        let before = try XCTUnwrap(store.fetchTask(id: task.id))
        try store.completeTask(id: task.id)
        XCTAssertTrue(try XCTUnwrap(store.fetchTask(id: task.id)).isCompleted)

        let restored = TaskUndo.restore([before], fields: [.completion], store: store)
        XCTAssertEqual(restored.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.fetchTask(id: task.id)).isCompleted)
    }

    func testRestoreSkipsTasksThatNoLongerExist() throws {
        let ghost = TodoTask(title: "Gone")
        XCTAssertTrue(TaskUndo.restore([ghost], fields: [.priority], store: store).isEmpty)
    }

    func testRestoreDeletedBringsBackTaskTagsAndChecklist() throws {
        let task = try store.createTask(title: "Groceries", priority: .medium, tags: ["home"])
        let item = try store.addSubtask(to: task.id, title: "Milk")
        try store.setSubtaskCompleted(id: item.id, isCompleted: true)
        _ = try store.addSubtask(to: task.id, title: "Eggs")

        let snapshot = try XCTUnwrap(TaskUndo.snapshotForDeletion(id: task.id, store: store))
        try store.deleteTask(id: task.id)
        XCTAssertNil(try store.fetchTask(id: task.id))

        let restored = try XCTUnwrap(TaskUndo.restoreDeleted(snapshot, store: store))
        XCTAssertEqual(restored.id, task.id)
        XCTAssertEqual(restored.title, "Groceries")
        XCTAssertEqual(restored.priority, .medium)
        XCTAssertEqual(try store.tags(for: task.id), ["home"])
        let subtasks = try store.subtasks(for: task.id)
        XCTAssertEqual(subtasks.map(\.title), ["Milk", "Eggs"])
        XCTAssertEqual(subtasks.map(\.isCompleted), [true, false])

        // The delete tombstone is gone, so sync sees a live task again.
        let side = try XCTUnwrap(store.localTaskSides()[task.id])
        XCTAssertFalse(side.isDeleted)
    }

    // MARK: - View model registration

    @MainActor
    func testViewModelRegistersUndoForCompletionAndDelete() throws {
        let database = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: database)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let vm = TaskListViewModel(filter: .all, store: store,
                                   reminderScheduler: NoOpTaskReminderScheduler())
        vm.undoManager = undoManager

        let created = try store.createTask(title: "Call Sam")
        let task = try XCTUnwrap(store.fetchTask(id: created.id))

        undoManager.beginUndoGrouping()
        vm.toggleCompleted(task)
        undoManager.endUndoGrouping()
        XCTAssertTrue(try XCTUnwrap(store.fetchTask(id: task.id)).isCompleted)
        XCTAssertEqual(undoManager.undoActionName, "Complete Task")

        undoManager.undo()
        XCTAssertFalse(try XCTUnwrap(store.fetchTask(id: task.id)).isCompleted)
        undoManager.redo()
        XCTAssertTrue(try XCTUnwrap(store.fetchTask(id: task.id)).isCompleted)

        let current = try XCTUnwrap(store.fetchTask(id: task.id))
        undoManager.beginUndoGrouping()
        vm.delete(current)
        undoManager.endUndoGrouping()
        XCTAssertNil(try store.fetchTask(id: task.id))
        XCTAssertEqual(undoManager.undoActionName, "Delete Task")

        undoManager.undo()
        XCTAssertNotNil(try store.fetchTask(id: task.id))
        undoManager.redo()
        XCTAssertNil(try store.fetchTask(id: task.id))
    }

    @MainActor
    func testViewModelRegistersUndoForPriorityChange() throws {
        let database = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: database)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let vm = TaskListViewModel(filter: .all, store: store,
                                   reminderScheduler: NoOpTaskReminderScheduler())
        vm.undoManager = undoManager

        let created = try store.createTask(title: "Review PR")
        let task = try XCTUnwrap(store.fetchTask(id: created.id))

        undoManager.beginUndoGrouping()
        vm.setPriority(.high, for: task)
        undoManager.endUndoGrouping()
        XCTAssertEqual(try XCTUnwrap(store.fetchTask(id: task.id)).priority, .high)
        XCTAssertEqual(undoManager.undoActionName, "Change Priority")

        undoManager.undo()
        XCTAssertNil(try XCTUnwrap(store.fetchTask(id: task.id)).priority)
    }
}
