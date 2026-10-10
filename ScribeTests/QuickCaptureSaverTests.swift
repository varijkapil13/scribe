import XCTest
@testable import Scribe

/// `QuickCaptureSaver` against an in-memory database and a temp vault.
final class QuickCaptureSaverTests: XCTestCase {

    private var root: URL!
    private var noteStore: NoteStore!
    private var taskStore: TaskStore!
    private var saver: QuickCaptureSaver!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCapture-\(UUID().uuidString)")
        let db = try DatabaseManager(path: ":memory:")
        noteStore = NoteStore(databaseManager: db, fileStore: NoteFileStore(directory: NotesDirectory(root: root)))
        taskStore = TaskStore(databaseManager: db)
        saver = QuickCaptureSaver(noteStore: noteStore, taskStore: taskStore)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        noteStore = nil
        taskStore = nil
        saver = nil
    }

    private let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current

    private func parse(_ line: String) -> QuickAddParser.ParsedQuickAdd {
        QuickAddParser.parse(line, detector: nil)
    }

    private func request(_ mode: QuickCaptureMode, _ text: String) throws -> QuickCaptureRequest {
        try XCTUnwrap(QuickCaptureComposer.request(mode: mode, text: text, parse: parse))
    }

    // MARK: - Note

    func testSavesNoteWithTitleAndBody() throws {
        let outcome = try saver.save(try request(.note, "Offsite ideas\nBoat trip"), now: Date(), timeZone: utc)
        guard case .note(let id) = outcome.destination else {
            return XCTFail("Expected a note, got \(outcome.destination)")
        }
        let note = try XCTUnwrap(try noteStore.fetchNote(id: id))
        XCTAssertEqual(note.title, "Offsite ideas")
        XCTAssertEqual(note.body, "Boat trip")
        XCTAssertNil(note.notebookId, "Quick notes land in the Inbox")
        XCTAssertEqual(outcome.selection, .note(id))
        XCTAssertEqual(outcome.message, "Note saved to Inbox")
    }

    // MARK: - Task

    func testSavesTaskIntoMatchingProject() throws {
        let project = try taskStore.createProject(name: "Errands")
        let outcome = try saver.save(
            try request(.task, "Buy milk #shopping +errands !high\noat, not dairy"),
            now: Date(),
            timeZone: utc
        )
        guard case .task(let id) = outcome.destination else {
            return XCTFail("Expected a task, got \(outcome.destination)")
        }
        let task = try XCTUnwrap(try taskStore.fetchTask(id: id))
        XCTAssertEqual(task.title, "Buy milk")
        XCTAssertEqual(task.notes, "oat, not dairy")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.projectId, project.id)
        XCTAssertNil(task.dueAt)
        XCTAssertEqual(try taskStore.tags(for: id), ["shopping"])
        XCTAssertEqual(outcome.selection, .task(id))
        XCTAssertEqual(outcome.message, "Task added to Errands")
    }

    func testUnknownProjectFallsBackToInbox() throws {
        _ = try taskStore.createProject(name: "Work")
        let outcome = try saver.save(try request(.task, "Call plumber +Home"), now: Date(), timeZone: utc)
        guard case .task(let id) = outcome.destination else {
            return XCTFail("Expected a task, got \(outcome.destination)")
        }
        let task = try XCTUnwrap(try taskStore.fetchTask(id: id))
        XCTAssertEqual(task.title, "Call plumber")
        XCTAssertNil(task.projectId)
        XCTAssertEqual(outcome.message, "Task added to Inbox")
    }

    func testMatchingProjectIsCaseInsensitive() {
        let projects = [Project(name: "Work"), Project(name: "Home")]
        XCTAssertEqual(QuickCaptureSaver.matchingProject(named: "home", in: projects)?.name, "Home")
        XCTAssertNil(QuickCaptureSaver.matchingProject(named: "Garden", in: projects))
    }

    // MARK: - Daily note

    func testAppendsTimestampedEntriesToTodaysDailyNote() throws {
        // The daily note's day is keyed in the device time zone, so build the
        // times there too: both entries then land on the same day anywhere.
        let local = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 15)))
        let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 10, minute: 45)))

        let first = try saver.save(try request(.appendToDaily, "Call Anna"), now: morning, timeZone: local)
        let second = try saver.save(try request(.appendToDaily, "Book flights\nfor the offsite"), now: later, timeZone: local)
        XCTAssertEqual(first.destination, second.destination, "Both entries go to the same daily note")
        XCTAssertEqual(second.message, "Added to today's daily note")

        guard case .note(let id) = second.destination else {
            return XCTFail("Expected a note, got \(second.destination)")
        }
        let note = try XCTUnwrap(try noteStore.fetchNote(id: id))
        XCTAssertTrue(note.isDailyNote)
        // The vault trims surrounding newlines when it reads a body back.
        XCTAssertEqual(
            note.body.trimmingCharacters(in: .newlines),
            "- 09:15 Call Anna\n- 10:45 Book flights\n  for the offsite"
        )
        XCTAssertEqual(try noteStore.fetchExistingDailyNote(for: morning)?.id, id)
    }

    func testAppendTellsOpenEditorsAboutTheChange() throws {
        let dailyId = try noteStore.dailyNote(for: Date()).id
        let posted = expectation(forNotification: .scribeNoteChangedInApp, object: nil) { notification in
            NoteVaultChange.noteIds(from: notification) == [dailyId]
        }
        _ = try saver.save(try request(.appendToDaily, "Ping"), now: Date(), timeZone: utc)
        wait(for: [posted], timeout: 1)
    }

    func testAppendKeepsExistingDailyContent() throws {
        let now = Date()
        var daily = try noteStore.dailyNote(for: now)
        daily.body = "# Plan\n\nShip the release"
        try noteStore.updateNote(daily, tags: ["daily"])

        _ = try saver.save(try request(.appendToDaily, "Lunch with Sam"), now: now, timeZone: utc)

        let note = try XCTUnwrap(try noteStore.fetchNote(id: daily.id))
        XCTAssertTrue(note.body.hasPrefix("# Plan\n\nShip the release\n\n- "), "Got: \(note.body)")
        XCTAssertTrue(note.body.trimmingCharacters(in: .newlines).hasSuffix(" Lunch with Sam"), "Got: \(note.body)")
        XCTAssertEqual(try noteStore.tags(for: daily.id), ["daily"], "Tags survive the append")
    }
}
