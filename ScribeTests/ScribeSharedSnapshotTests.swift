import XCTest
@testable import Scribe

/// The App Group snapshot the widgets read (`ScribeSharedSnapshot`) and the
/// app-side mapping that builds it (`WidgetSnapshotPublisher.makeSnapshot`).
final class ScribeSharedSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedSnapshot-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func task(_ id: String, completed: Bool = false) -> ScribeSharedSnapshot.TaskItem {
        ScribeSharedSnapshot.TaskItem(id: id, title: "Task \(id)", due: now, priority: .high, isCompleted: completed)
    }

    private func meeting(_ id: String, startOffset: TimeInterval, minutes: TimeInterval = 30) -> ScribeSharedSnapshot.Meeting {
        ScribeSharedSnapshot.Meeting(
            id: id,
            title: "Meeting \(id)",
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + minutes * 60)
        )
    }

    // MARK: - Coding

    func testEncodeDecodeRoundTrip() throws {
        let snapshot = ScribeSharedSnapshot.make(
            now: now,
            tasks: [
                task("a"),
                ScribeSharedSnapshot.TaskItem(id: "b", title: "No due", due: nil, priority: nil, isCompleted: true),
            ],
            meetings: [meeting("m", startOffset: 600)],
            recording: ScribeSharedSnapshot.RecordingState(isRecording: true, startedAt: now.addingTimeInterval(-90))
        )
        let decoded = try ScribeSharedSnapshot.decode(try snapshot.encoded())
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.version, ScribeSharedSnapshot.currentVersion)
        XCTAssertNil(decoded.tasks[1].due)
        XCTAssertNil(decoded.tasks[1].priority)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try ScribeSharedSnapshot.decode(Data("not json".utf8)))
    }

    func testStoreWritesAndReadsBack() throws {
        let store = ScribeSharedSnapshotStore(directory: tempDir)
        XCTAssertNil(store.read(), "Nothing written yet")
        let snapshot = ScribeSharedSnapshot.make(now: now, tasks: [task("a")], meetings: [], recording: .idle)
        try store.write(snapshot)
        XCTAssertEqual(store.read(), snapshot)
        XCTAssertEqual(store.fileURL.lastPathComponent, ScribeAppGroup.snapshotFileName)
    }

    // MARK: - Limits and ordering

    func testMakeKeepsTopEightTasks() {
        let tasks = (1...12).map { task("t\($0)") }
        let snapshot = ScribeSharedSnapshot.make(now: now, tasks: tasks, meetings: [], recording: .idle)
        XCTAssertEqual(snapshot.tasks.count, ScribeSharedSnapshot.maxTasks)
        XCTAssertEqual(snapshot.tasks.map(\.id), (1...8).map { "t\($0)" })
    }

    func testMakeKeepsNextThreeMeetingsSoonestFirstAndDropsEnded() {
        let meetings = [
            meeting("later", startOffset: 4 * 3600),
            meeting("ended", startOffset: -3600, minutes: 30),
            meeting("inProgress", startOffset: -600, minutes: 30),
            meeting("soon", startOffset: 900),
            meeting("tomorrow", startOffset: 20 * 3600),
        ]
        let snapshot = ScribeSharedSnapshot.make(now: now, tasks: [], meetings: meetings, recording: .idle)
        XCTAssertEqual(snapshot.meetings.map(\.id), ["inProgress", "soon", "later"])
        XCTAssertEqual(snapshot.nextMeeting(at: now)?.id, "inProgress")
        XCTAssertTrue(snapshot.meetings[0].isInProgress(at: now))
        XCTAssertFalse(snapshot.meetings[1].isInProgress(at: now))
        // Once the in-progress meeting ends, the next one takes over.
        XCTAssertEqual(snapshot.nextMeeting(at: now.addingTimeInterval(25 * 60))?.id, "soon")
    }

    func testEmptySnapshotHasNothing() {
        let empty = ScribeSharedSnapshot.empty(at: now)
        XCTAssertTrue(empty.tasks.isEmpty)
        XCTAssertTrue(empty.meetings.isEmpty)
        XCTAssertFalse(empty.recording.isRecording)
        XCTAssertNil(empty.nextMeeting(at: now))
    }

    // MARK: - Widget-side updates

    func testApplyingCompletionTouchesOnlyThatTask() {
        let snapshot = ScribeSharedSnapshot.make(now: now, tasks: [task("a"), task("b")], meetings: [], recording: .idle)
        let toggled = snapshot.applyingCompletion(taskId: "b", isCompleted: true)
        XCTAssertEqual(toggled.tasks.map(\.isCompleted), [false, true])
        XCTAssertEqual(toggled.applyingCompletion(taskId: "b", isCompleted: false), snapshot)
        XCTAssertEqual(snapshot.applyingCompletion(taskId: "missing", isCompleted: true), snapshot)
    }

    func testSameContentIgnoresGeneratedAt() {
        let a = ScribeSharedSnapshot.make(now: now, tasks: [task("a")], meetings: [], recording: .idle)
        var b = a
        b.generatedAt = now.addingTimeInterval(60)
        XCTAssertTrue(a.hasSameContent(as: b))
        b.recording = ScribeSharedSnapshot.RecordingState(isRecording: true, startedAt: now)
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    // MARK: - App-side mapping

    func testPublisherMapsTasksAndEvents() {
        let open = TodoTask(id: "open", title: "Write report", priority: .high, dueAt: now)
        let done = TodoTask(id: "done", title: "Old", completedAt: now)
        let cancelled = TodoTask(id: "cancelled", title: "Nope", cancelledAt: now)
        let low = TodoTask(id: "low", title: "Low one", priority: .low)
        let events = [
            CalendarEventInfo(id: "ev", title: "Standup", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1500)),
            CalendarEventInfo(id: "allday", title: "Holiday", start: now, end: now.addingTimeInterval(86_400), isAllDay: true),
        ]
        let snapshot = WidgetSnapshotPublisher.makeSnapshot(
            now: now,
            tasks: [open, done, cancelled, low],
            events: events,
            recording: .idle
        )
        XCTAssertEqual(snapshot.tasks.map(\.id), ["open", "done", "low"], "Cancelled tasks are dropped")
        XCTAssertEqual(snapshot.tasks[0].priority, .high)
        XCTAssertEqual(snapshot.tasks[0].due, now)
        XCTAssertFalse(snapshot.tasks[0].isCompleted)
        XCTAssertTrue(snapshot.tasks[1].isCompleted)
        XCTAssertEqual(snapshot.tasks[2].priority, .low)
        XCTAssertEqual(snapshot.meetings.map(\.title), ["Standup"], "All-day events aren't meetings")
        XCTAssertTrue(snapshot.meetings[0].id.hasPrefix("ev@"))
    }

    func testPriorityMapping() {
        XCTAssertEqual(WidgetSnapshotPublisher.priority(.high), .high)
        XCTAssertEqual(WidgetSnapshotPublisher.priority(.medium), .medium)
        XCTAssertEqual(WidgetSnapshotPublisher.priority(.low), .low)
        XCTAssertNil(WidgetSnapshotPublisher.priority(nil))
    }

    // MARK: - Deep links used by the extensions

    func testExtensionDeepLinksParse() {
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.recordStartURL), .startRecording)
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.todayURL), .today)
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.importShareURL), .importShared)
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.taskURL(id: "t-1")), .task(id: "t-1"))
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.taskURL(id: "a b/c")), .task(id: "a b/c"))
    }
}
