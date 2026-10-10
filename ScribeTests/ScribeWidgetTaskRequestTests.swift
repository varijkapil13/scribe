import XCTest
@testable import Scribe

/// Widget → app task toggles: the queue in the App Group and the app-side
/// applier, against an in-memory database and a temp folder.
@MainActor
final class ScribeWidgetTaskRequestTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetRequests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    // MARK: - Collapsing

    func testLatestRequestPerTaskWins() {
        let requests = [
            ScribeWidgetTaskRequest(taskId: "a", isCompleted: true, requestedAt: t0),
            ScribeWidgetTaskRequest(taskId: "b", isCompleted: true, requestedAt: t0),
            ScribeWidgetTaskRequest(taskId: "a", isCompleted: false, requestedAt: t0.addingTimeInterval(2)),
            // Older than the one above even though queued later: ignored.
            ScribeWidgetTaskRequest(taskId: "a", isCompleted: true, requestedAt: t0.addingTimeInterval(1)),
        ]
        let latest = ScribeWidgetTaskRequest.latestPerTask(requests)
        XCTAssertEqual(latest.map(\.taskId), ["a", "b"])
        XCTAssertEqual(latest.map(\.isCompleted), [false, true])
    }

    func testSameTimestampLaterInQueueWins() {
        let requests = [
            ScribeWidgetTaskRequest(taskId: "a", isCompleted: true, requestedAt: t0),
            ScribeWidgetTaskRequest(taskId: "a", isCompleted: false, requestedAt: t0),
        ]
        XCTAssertEqual(ScribeWidgetTaskRequest.latestPerTask(requests).first?.isCompleted, false)
    }

    // MARK: - Queue

    func testQueueEnqueueAndDrainOldestFirst() throws {
        let queue = ScribeWidgetRequestQueue(container: tempDir)
        XCTAssertTrue(queue.drain().isEmpty, "Missing folder drains to nothing")
        try queue.enqueue(ScribeWidgetTaskRequest(taskId: "late", isCompleted: true, requestedAt: t0.addingTimeInterval(5)))
        try queue.enqueue(ScribeWidgetTaskRequest(taskId: "early", isCompleted: false, requestedAt: t0))
        let drained = queue.drain()
        XCTAssertEqual(drained.map(\.taskId), ["early", "late"])
        XCTAssertEqual(drained.map(\.isCompleted), [false, true])
        XCTAssertTrue(queue.drain().isEmpty, "Draining removes the files")
        XCTAssertEqual(queue.directory.lastPathComponent, ScribeAppGroup.widgetRequestsFolderName)
    }

    func testQueueDiscardsUnreadableFiles() throws {
        let queue = ScribeWidgetRequestQueue(container: tempDir)
        try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
        let junk = queue.directory.appendingPathComponent("junk.json")
        try Data("{".utf8).write(to: junk)
        XCTAssertTrue(queue.drain().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
    }

    // MARK: - Applier

    func testActionDecision() {
        let open = TodoTask(id: "t", title: "Open")
        let done = TodoTask(id: "t", title: "Done", completedAt: t0)
        let cancelled = TodoTask(id: "t", title: "Cancelled", cancelledAt: t0)
        let complete = ScribeWidgetTaskRequest(taskId: "t", isCompleted: true, requestedAt: t0)
        let reopen = ScribeWidgetTaskRequest(taskId: "t", isCompleted: false, requestedAt: t0)

        XCTAssertEqual(WidgetTaskRequestApplier.action(for: complete, task: open), .complete)
        XCTAssertEqual(WidgetTaskRequestApplier.action(for: complete, task: done), .noChange)
        XCTAssertEqual(WidgetTaskRequestApplier.action(for: reopen, task: done), .uncomplete)
        XCTAssertEqual(WidgetTaskRequestApplier.action(for: reopen, task: open), .noChange)
        XCTAssertEqual(WidgetTaskRequestApplier.action(for: complete, task: cancelled), .noChange)
        XCTAssertEqual(WidgetTaskRequestApplier.action(for: complete, task: nil), .noChange)
    }

    func testApplierCompletesAndReopensTasks() throws {
        let db = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: db)
        let first = try store.createTask(title: "Water plants")
        let second = try store.createTask(title: "Call Sam")
        try store.completeTask(id: second.id)

        let queue = ScribeWidgetRequestQueue(container: tempDir)
        let recorder = ChangedTaskRecorder()
        let applier = WidgetTaskRequestApplier(queue: queue, taskStore: store, onTaskChanged: { task in
            recorder.ids.append(task.id)
        })

        try queue.enqueue(ScribeWidgetTaskRequest(taskId: first.id, isCompleted: true, requestedAt: t0))
        try queue.enqueue(ScribeWidgetTaskRequest(taskId: second.id, isCompleted: false, requestedAt: t0))
        try queue.enqueue(ScribeWidgetTaskRequest(taskId: "missing", isCompleted: true, requestedAt: t0))

        XCTAssertEqual(applier.drain(), 2)
        let firstAfter = try XCTUnwrap(try store.fetchTask(id: first.id))
        let secondAfter = try XCTUnwrap(try store.fetchTask(id: second.id))
        XCTAssertTrue(firstAfter.isCompleted)
        XCTAssertFalse(secondAfter.isCompleted)
        XCTAssertEqual(Set(recorder.ids), Set([first.id, second.id]))

        // A repeated request is a no-op (no second completion logged).
        try queue.enqueue(ScribeWidgetTaskRequest(taskId: first.id, isCompleted: true, requestedAt: t0))
        XCTAssertEqual(applier.drain(), 0)
    }
}

/// Collects the ids the applier reports as changed.
@MainActor
private final class ChangedTaskRecorder {
    var ids: [String] = []
}
