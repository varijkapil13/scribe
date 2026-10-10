import XCTest
@testable import Scribe

/// Share extension → app hand-off: the inbox folder format, the text
/// composition and the importer (in-memory database + temp vault).
final class ScribeShareInboxTests: XCTestCase {

    private var root: URL!
    private var vaultRoot: URL!
    private var inbox: ScribeShareInbox!
    private var noteStore: NoteStore!
    private var taskStore: TaskStore!
    private var importer: ScribeShareInboxImporter!

    private let created = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current

    // A 1×1 PNG.
    private let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ) ?? Data([0x89, 0x50, 0x4E, 0x47])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInbox-\(UUID().uuidString)", isDirectory: true)
        vaultRoot = root.appendingPathComponent("Vault", isDirectory: true)
        inbox = ScribeShareInbox(container: root.appendingPathComponent("Group", isDirectory: true))
        let db = try DatabaseManager(path: ":memory:")
        noteStore = NoteStore(databaseManager: db, fileStore: NoteFileStore(directory: NotesDirectory(root: vaultRoot)))
        taskStore = TaskStore(databaseManager: db)
        importer = ScribeShareInboxImporter(
            noteStore: noteStore,
            taskStore: taskStore,
            inbox: inbox,
            attachmentsRoot: vaultRoot
        )
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        vaultRoot = nil
        inbox = nil
        noteStore = nil
        taskStore = nil
        importer = nil
    }

    private func payload(
        _ destination: ScribeSharePayload.Destination,
        title: String = "",
        text: String = "",
        urls: [String] = []
    ) -> ScribeSharePayload {
        ScribeSharePayload(
            createdAt: created,
            destination: destination,
            title: title,
            text: text,
            urls: urls,
            imageFileNames: []
        )
    }

    // MARK: - Payload coding and inbox format

    func testPayloadRoundTripsThroughInbox() throws {
        let original = payload(.newTask, title: "Read", text: "Some text", urls: ["https://example.com/a"])
        let folder = try inbox.write(original, images: [
            ScribeShareImage(data: pngData, fileExtension: "PNG"),
            ScribeShareImage(data: pngData, fileExtension: "../weird"),
        ])
        XCTAssertEqual(inbox.pendingItemFolders().map(\.lastPathComponent), [original.id])
        let read = try inbox.readPayload(in: folder)
        XCTAssertEqual(read.id, original.id)
        XCTAssertEqual(read.destination, .newTask)
        XCTAssertEqual(read.urls, ["https://example.com/a"])
        XCTAssertEqual(read.imageFileNames, ["image-1.png", "image-2.weird"])
        XCTAssertNotNil(inbox.imageURL(named: "image-1.png", in: folder))
        XCTAssertNil(inbox.imageURL(named: "../payload.json", in: folder))
        XCTAssertNil(inbox.imageURL(named: "missing.png", in: folder))
    }

    func testFolderWithoutPayloadIsNotPending() throws {
        let partial = inbox.directory.appendingPathComponent("in-progress", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try pngData.write(to: partial.appendingPathComponent("image-1.png"))
        XCTAssertTrue(inbox.pendingItemFolders().isEmpty)
    }

    func testSafeNames() {
        XCTAssertTrue(ScribeShareInbox.isSafeFileName("image-1.png"))
        XCTAssertFalse(ScribeShareInbox.isSafeFileName(".."))
        XCTAssertFalse(ScribeShareInbox.isSafeFileName(".hidden"))
        XCTAssertFalse(ScribeShareInbox.isSafeFileName("a/b"))
        XCTAssertEqual(ScribeShareInbox.safeExtension("JPG"), "jpg")
        XCTAssertEqual(ScribeShareInbox.safeExtension(""), "png")
    }

    // MARK: - Composer

    func testResolvedTitlePrefersTypedThenFirstLineThenHost() {
        XCTAssertEqual(ScribeShareComposer.resolvedTitle(for: payload(.newNote, title: " Typed ", text: "Line")), "Typed")
        XCTAssertEqual(ScribeShareComposer.resolvedTitle(for: payload(.newNote, text: "\n  First line\nSecond")), "First line")
        XCTAssertEqual(ScribeShareComposer.resolvedTitle(for: payload(.newNote, urls: ["https://www.apple.com/mac"])), "www.apple.com")
        XCTAssertEqual(ScribeShareComposer.resolvedTitle(for: payload(.newNote)), ScribeShareComposer.fallbackTitle)
    }

    func testBodyCombinesTextLinksAndImages() {
        let shared = payload(.newNote, title: "T", text: "Hello\nWorld", urls: ["https://example.com"])
        XCTAssertEqual(
            ScribeShareComposer.body(for: shared, imageLinks: ["attachments/n/image-1.png"]),
            "Hello\nWorld\n\n- <https://example.com>\n\n![](attachments/n/image-1.png)"
        )
        XCTAssertEqual(ScribeShareComposer.body(for: shared, imageLinks: [], dropFirstLine: true),
                       "World\n\n- <https://example.com>")
    }

    func testInboxEntryAndAppending() {
        let shared = payload(.appendToInbox, text: "Idea\nDetails", urls: [])
        let entry = ScribeShareComposer.inboxEntry(for: shared, imageLinks: [], timeZone: utc)
        XCTAssertEqual(entry, "### Idea · 2027-01-15 08:00\n\nDetails")
        XCTAssertEqual(ScribeShareComposer.appending("B", to: "A\n\n\n"), "A\n\nB\n")
        XCTAssertEqual(ScribeShareComposer.appending("B", to: ""), "B\n")
    }

    // MARK: - Importer

    func testImportsNewNoteWithImageAttachment() throws {
        try inbox.write(payload(.newNote, title: "Screenshot", text: "Look at this"),
                        images: [ScribeShareImage(data: pngData, fileExtension: "png")])

        let result = importer.importPending(timeZone: utc)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.outcomes.count, 1)
        guard case .note(let id) = result.outcomes[0].destination else {
            return XCTFail("Expected a note, got \(result.outcomes[0].destination)")
        }
        let note = try XCTUnwrap(try noteStore.fetchNote(id: id))
        XCTAssertEqual(note.title, "Screenshot")
        XCTAssertTrue(note.body.hasPrefix("Look at this\n\n![](attachments/\(id)/"), note.body)
        let attachments = try FileManager.default.contentsOfDirectory(
            atPath: vaultRoot.appendingPathComponent("attachments/\(id)").path
        )
        XCTAssertEqual(attachments.count, 1)
        XCTAssertTrue(inbox.pendingItemFolders().isEmpty, "Imported items are removed")
    }

    func testImportsTaskWithLinksInNotes() throws {
        try inbox.write(payload(.newTask, text: "Read later\nlong article", urls: ["https://example.com/post"]),
                        images: [])
        let result = importer.importPending(timeZone: utc)
        guard case .task(let id)? = result.outcomes.first?.destination else {
            return XCTFail("Expected a task, got \(result.outcomes)")
        }
        let task = try XCTUnwrap(try taskStore.fetchTask(id: id))
        XCTAssertEqual(task.title, "Read later")
        XCTAssertEqual(task.notes, "long article\n\n- <https://example.com/post>")
        XCTAssertEqual(result.outcomes.first?.selection, .task(id))
    }

    func testAppendsToInboxNoteCreatingItOnce() throws {
        try inbox.write(payload(.appendToInbox, title: "First", text: "one"), images: [])
        let firstResult = importer.importPending(timeZone: utc)
        guard case .note(let inboxId)? = firstResult.outcomes.first?.destination else {
            return XCTFail("Expected a note, got \(firstResult.outcomes)")
        }

        try inbox.write(payload(.appendToInbox, title: "Second", text: "two"), images: [])
        let secondResult = importer.importPending(timeZone: utc)
        XCTAssertEqual(secondResult.outcomes.first?.destination, .note(id: inboxId), "Same Inbox note reused")

        let note = try XCTUnwrap(try noteStore.fetchNote(id: inboxId))
        XCTAssertEqual(note.title, ScribeShareComposer.inboxNoteTitle)
        XCTAssertTrue(note.body.contains("### First · 2027-01-15 08:00\n\none"), note.body)
        XCTAssertTrue(note.body.contains("### Second · 2027-01-15 08:00\n\ntwo"), note.body)
        let firstRange = try XCTUnwrap(note.body.range(of: "### First"))
        let secondRange = try XCTUnwrap(note.body.range(of: "### Second"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }

    func testCorruptPayloadIsDiscarded() throws {
        let folder = inbox.directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent(ScribeShareInbox.payloadFileName))

        let result = importer.importPending(timeZone: utc)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testEmptyPayloadIsDroppedSilently() throws {
        try inbox.write(payload(.newNote), images: [])
        let result = importer.importPending(timeZone: utc)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(inbox.pendingItemFolders().isEmpty)
    }
}
