import XCTest
@testable import Scribe

/// `UndoableActions`: undo/redo pairs cycle on a real `UndoManager`.
@MainActor
final class UndoableActionsTests: XCTestCase {

    private final class Recorder {
        var events: [String] = []
    }

    private func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        // Tests have no run loop turning events into undo groups.
        manager.groupsByEvent = false
        return manager
    }

    func testUndoRedoCycle() {
        let manager = makeUndoManager()
        let recorder = Recorder()

        manager.beginUndoGrouping()
        UndoableActions.register(on: manager, actionName: "Complete Task",
                                 undo: { recorder.events.append("undo") },
                                 redo: { recorder.events.append("redo") })
        manager.endUndoGrouping()

        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "Complete Task")

        manager.undo()
        XCTAssertEqual(recorder.events, ["undo"])
        XCTAssertTrue(manager.canRedo)
        XCTAssertEqual(manager.redoActionName, "Complete Task")

        manager.redo()
        XCTAssertEqual(recorder.events, ["undo", "redo"])
        XCTAssertTrue(manager.canUndo)

        manager.undo()
        XCTAssertEqual(recorder.events, ["undo", "redo", "undo"])
    }

    func testNilUndoManagerIsANoOp() {
        let recorder = Recorder()
        UndoableActions.register(on: nil, actionName: "Anything",
                                 undo: { recorder.events.append("undo") },
                                 redo: { recorder.events.append("redo") })
        XCTAssertTrue(recorder.events.isEmpty)
    }
}
