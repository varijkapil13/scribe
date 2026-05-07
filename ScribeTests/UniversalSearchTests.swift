// ScribeTests/UniversalSearchTests.swift
import XCTest
@testable import Scribe

final class UniversalSearchTests: XCTestCase {
    private var db: DatabaseManager!
    private var noteStore: NoteStore!
    private var taskStore: TaskStore!

    override func setUp() {
        db = try! DatabaseManager(path: ":memory:")
        noteStore = NoteStore(databaseManager: db)
        taskStore = TaskStore(databaseManager: db)
    }

    func testSearchNotesReturnsMatches() throws {
        _ = try noteStore.createNote(title: "Alpha", body: "unique keyword here", tags: [])
        _ = try noteStore.createNote(title: "Beta", body: "different content", tags: [])
        let results = try noteStore.searchNotes(query: "unique")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Alpha")
    }

    func testSearchNotesEmptyQueryReturnsAll() throws {
        _ = try noteStore.createNote(title: "A", body: "", tags: [])
        _ = try noteStore.createNote(title: "B", body: "", tags: [])
        let results = try noteStore.searchNotes(query: "")
        XCTAssertEqual(results.count, 2)
    }

    func testSearchTasksReturnsMatches() throws {
        let matched = try taskStore.createTask(title: "Buy groceries", notes: "get milk")
        _ = try taskStore.createTask(title: "Read book", notes: "fiction")
        let results = try taskStore.searchTasks(query: "groceries")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, matched.id)
    }

    func testSearchTasksEmptyQueryReturnsEmpty() throws {
        _ = try taskStore.createTask(title: "Some task")
        let results = try taskStore.searchTasks(query: "")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchNotesAndTasksIndependent() throws {
        _ = try noteStore.createNote(title: "Meeting notes", body: "discussed budget", tags: [])
        _ = try taskStore.createTask(title: "Prepare budget report")
        let noteResults = try noteStore.searchNotes(query: "budget")
        let taskResults = try taskStore.searchTasks(query: "budget")
        XCTAssertEqual(noteResults.count, 1)
        XCTAssertEqual(taskResults.count, 1)
    }
}
