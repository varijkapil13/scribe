import XCTest
@testable import Scribe

/// Covers the editor view model's pure helpers and its save/duplicate/delete
/// flows against an in-memory `TaskStore`.
final class TaskEditorViewModelTests: XCTestCase {

    // MARK: - Tag parsing

    func testParseTagsTrimsLowercasesAndDeduplicates() {
        XCTAssertEqual(
            TaskEditorViewModel.parseTags("Work, errands, WORK,  shopping  "),
            ["work", "errands", "shopping"]
        )
    }

    func testParseTagsHandlesNewlinesAndEmpties() {
        XCTAssertEqual(
            TaskEditorViewModel.parseTags(",, work\nhome ,, "),
            ["work", "home"]
        )
    }

    // MARK: - Round-trip integration

    @MainActor
    func testSavePersistsAllEditableFieldsAndTags() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let project = try store.createProject(name: "Work")
        let original = try store.createTask(title: "Original", tags: ["old"])

        let vm = TaskEditorViewModel(task: original, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        vm.title = "Renamed"
        vm.notes = "Some notes"
        vm.projectId = project.id
        vm.priority = .high
        vm.dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        vm.tagsInput = "alpha, BETA"

        XCTAssertTrue(vm.save())

        let updated = try XCTUnwrap(store.fetchTask(id: original.id))
        XCTAssertEqual(updated.title, "Renamed")
        XCTAssertEqual(updated.notes, "Some notes")
        XCTAssertEqual(updated.projectId, project.id)
        XCTAssertEqual(updated.priority, .high)
        XCTAssertEqual(updated.dueAt?.timeIntervalSince1970, 1_800_000_000)

        let tags = try store.tags(for: original.id)
        XCTAssertEqual(tags, ["alpha", "beta"])
    }

    @MainActor
    func testSaveRejectsBlankTitle() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let task = try store.createTask(title: "Keep me")

        let vm = TaskEditorViewModel(task: task, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        vm.title = "   "
        XCTAssertFalse(vm.save())
        XCTAssertEqual(vm.saveError, "Title can't be empty.")

        // Original row is untouched.
        let unchanged = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertEqual(unchanged.title, "Keep me")
    }

    @MainActor
    func testDuplicateCreatesIndependentCopyWithSameTags() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let original = try store.createTask(title: "Dup me", tags: ["work"])

        let vm = TaskEditorViewModel(task: original, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        let copy = try XCTUnwrap(vm.duplicate())
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.title, "Dup me")
        XCTAssertEqual(try store.tags(for: copy.id), ["work"])
    }

    @MainActor
    func testDeleteRemovesRow() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let task = try store.createTask(title: "Bye")

        let vm = TaskEditorViewModel(task: task, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        vm.delete()
        XCTAssertNil(try store.fetchTask(id: task.id))
    }
}
