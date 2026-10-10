import XCTest
@testable import Scribe

/// Portable logic behind the iOS system integration (ScribeiOS/System):
/// Quick Capture planning, the widget snapshot mapping, PDF hand-off from
/// the iOS Share extension and the App Group deep links.
final class ScribeiOSSystemIntegrationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    // MARK: - Quick Capture

    func testNoteCaptureKeepsTitleAndBody() {
        let plan = ScribeQuickCapturePlan.make(
            kind: .note, title: "  Idea  ", body: "Details\nMore\n", now: now, calendar: calendar
        )
        XCTAssertEqual(plan, .note(title: "Idea", body: "Details\nMore"))
    }

    func testNoteCaptureWithoutTitleUsesFirstBodyLine() {
        let plan = ScribeQuickCapturePlan.make(
            kind: .note, title: "", body: "\n  Groceries \nmilk\neggs", now: now, calendar: calendar
        )
        XCTAssertEqual(plan, .note(title: "Groceries", body: "milk\neggs"))
    }

    func testEmptyCaptureHasNoPlan() {
        XCTAssertNil(ScribeQuickCapturePlan.make(kind: .note, title: " ", body: "\n\n", now: now, calendar: calendar))
        XCTAssertNil(ScribeQuickCapturePlan.make(kind: .task, title: "", body: "", now: now, calendar: calendar))
    }

    func testTaskCaptureParsesQuickAddTokens() {
        let plan = ScribeQuickCapturePlan.make(
            kind: .task, title: "Call Sam #work !high", body: "about the launch", now: now, calendar: calendar
        )
        guard case .task(let parsed, let notes)? = plan else {
            return XCTFail("Expected a task plan, got \(String(describing: plan))")
        }
        XCTAssertEqual(parsed.title, "Call Sam")
        XCTAssertEqual(parsed.tags, ["work"])
        XCTAssertEqual(parsed.priority, .high)
        XCTAssertEqual(notes, "about the launch")
    }

    func testTaskCaptureOfOnlyTokensKeepsRawTitle() {
        let plan = ScribeQuickCapturePlan.make(kind: .task, title: "#errand", body: "", now: now, calendar: calendar)
        guard case .task(let parsed, _)? = plan else {
            return XCTFail("Expected a task plan, got \(String(describing: plan))")
        }
        XCTAssertEqual(parsed.title, "#errand")
    }

    func testSplitFirstLine() {
        XCTAssertEqual(ScribeQuickCapturePlan.splitFirstLine("").first, "")
        let split = ScribeQuickCapturePlan.splitFirstLine("\n\n a \n b \n")
        XCTAssertEqual(split.first, "a")
        XCTAssertEqual(split.rest, "b")
    }

    // MARK: - Widget snapshot mapping

    func testSnapshotBuilderDropsCancelledTasksAndAllDayEvents() {
        let open = TodoTask(id: "open", title: "Write report", priority: .medium, dueAt: now)
        let cancelled = TodoTask(id: "gone", title: "Cancelled", cancelledAt: now)
        let events = [
            ScribeWidgetSnapshotBuilder.Event(
                id: "e1", title: "Sync",
                start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), isAllDay: false
            ),
            ScribeWidgetSnapshotBuilder.Event(
                id: "holiday", title: "Holiday",
                start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(80_000), isAllDay: true
            ),
        ]
        let snapshot = ScribeWidgetSnapshotBuilder.snapshot(
            now: now, tasks: [open, cancelled], events: events, recording: .idle
        )
        XCTAssertEqual(snapshot.tasks.map(\.id), ["open"])
        XCTAssertEqual(snapshot.tasks.first?.priority, .medium)
        XCTAssertEqual(snapshot.meetings.map(\.title), ["Sync"])
        XCTAssertEqual(snapshot.meetings.first?.id, "e1@\(Int(now.addingTimeInterval(600).timeIntervalSince1970))")
        XCTAssertFalse(snapshot.recording.isRecording)
    }

    func testSnapshotBuilderMatchesMacPublisherMapping() {
        let task = TodoTask(id: "t", title: "Plan", priority: .low, dueAt: now, completedAt: now)
        XCTAssertEqual(ScribeWidgetSnapshotBuilder.taskItem(task), WidgetSnapshotPublisher.taskItem(task))
        for priority in [TodoTask.Priority.high, .medium, .low] {
            XCTAssertEqual(ScribeWidgetSnapshotBuilder.priority(priority), WidgetSnapshotPublisher.priority(priority))
        }
        XCTAssertNil(ScribeWidgetSnapshotBuilder.priority(nil))
    }

    // MARK: - Share extension PDFs

    func testAttachmentMarkdownEmbedsImagesAndLinksDocuments() {
        XCTAssertEqual(ScribeShareComposer.attachmentMarkdown("attachments/n/image-1.png"), "![](attachments/n/image-1.png)")
        XCTAssertEqual(
            ScribeShareComposer.attachmentMarkdown("attachments/n/document-1.pdf"),
            "[document-1.pdf](attachments/n/document-1.pdf)"
        )
    }

    func testInboxNamesPDFsAsDocuments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSShare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScribeShareInbox(container: root)
        let payload = ScribeSharePayload(
            createdAt: now, destination: .newNote, title: "Doc", text: "", urls: [], imageFileNames: []
        )
        let folder = try inbox.write(payload, images: [
            ScribeShareImage(data: Data("%PDF-1.4".utf8), fileExtension: "PDF"),
            ScribeShareImage(data: Data([0x89, 0x50]), fileExtension: "png"),
        ])
        XCTAssertEqual(try inbox.readPayload(in: folder).imageFileNames, ["document-1.pdf", "image-2.png"])
        XCTAssertTrue(ScribeShareInbox.isDocumentExtension("pdf"))
        XCTAssertFalse(ScribeShareInbox.isDocumentExtension("png"))
    }

    func testImportsSharedPDFIntoNoteAsLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSShareImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultRoot = root.appendingPathComponent("Vault", isDirectory: true)
        let inbox = ScribeShareInbox(container: root.appendingPathComponent("Group", isDirectory: true))
        let db = try DatabaseManager(path: ":memory:")
        let noteStore = NoteStore(databaseManager: db, fileStore: NoteFileStore(directory: NotesDirectory(root: vaultRoot)))
        let importer = ScribeShareInboxImporter(
            noteStore: noteStore,
            taskStore: TaskStore(databaseManager: db),
            inbox: inbox,
            attachmentsRoot: vaultRoot
        )
        let payload = ScribeSharePayload(
            createdAt: now, destination: .newNote, title: "Invoice", text: "", urls: [], imageFileNames: []
        )
        try inbox.write(payload, images: [ScribeShareImage(data: Data("%PDF-1.4 test".utf8), fileExtension: "pdf")])

        let result = importer.importPending(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        guard case .note(let id)? = result.outcomes.first?.destination else {
            return XCTFail("Expected a note, got \(result.outcomes)")
        }
        let note = try XCTUnwrap(try noteStore.fetchNote(id: id))
        XCTAssertTrue(note.body.hasPrefix("[document-1.pdf](attachments/\(id)/document-1"), note.body)
        XCTAssertEqual(result.outcomes.first?.deepLinkURL, ScribeAppGroup.noteURL(id: id))
    }

    // MARK: - Deep links

    func testNoteURLMatchesDeepLinkGrammar() {
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.noteURL(id: "n-1")), .note(id: "n-1"))
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.noteURL(id: "a b/c")), .note(id: "a b/c"))
        XCTAssertEqual(ScribeDeepLink.parse(ScribeAppGroup.recordStartURL), .startRecording)
    }
}
