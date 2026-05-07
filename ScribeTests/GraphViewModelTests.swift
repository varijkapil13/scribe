// ScribeTests/GraphViewModelTests.swift
import XCTest
@testable import Scribe

@MainActor
final class GraphViewModelTests: XCTestCase {
    private var db: DatabaseManager!
    private var noteStore: NoteStore!

    override func setUp() {
        db = try! DatabaseManager(path: ":memory:")
        noteStore = NoteStore(databaseManager: db)
    }

    func testNodesCreatedForNotes() throws {
        _ = try noteStore.createNote(title: "A", body: "", tags: [])
        _ = try noteStore.createNote(title: "B", body: "", tags: [])
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertEqual(vm.nodes.filter { $0.type == .note }.count, 2)
    }

    func testEdgesCreatedForWikiLinks() throws {
        let a = try noteStore.createNote(title: "Alpha", body: "[[Beta]]", tags: [])
        _ = try noteStore.createNote(title: "Beta", body: "", tags: [])
        try noteStore.updateNote(a, tags: [])
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertEqual(vm.edges.count, 1)
        XCTAssertEqual(vm.edges[0].sourceId, a.id)
    }

    func testEmptyGraphIsSettled() throws {
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertTrue(vm.isSettled)
    }

    func testIsSettledFalseWithNodes() throws {
        _ = try noteStore.createNote(title: "X", body: "", tags: [])
        _ = try noteStore.createNote(title: "Y", body: "", tags: [])
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertFalse(vm.isSettled)
    }
}
