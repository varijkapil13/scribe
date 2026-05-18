// ScribeTests/NoteConflictDetectorTests.swift
import XCTest
@testable import Scribe

/// Slice 6 contract: filename-based detection of iCloud Drive / Dropbox
/// style conflict files in the vault root.
final class NoteConflictDetectorTests: XCTestCase {

    private var tempRoot: URL!
    private var fileStore: NoteFileStore!
    private var detector: NoteConflictDetector!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileStore = NoteFileStore(directory: NotesDirectory(root: tempRoot))
        detector = NoteConflictDetector(fileStore: fileStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Pure pattern tests

    func testStripsICloudDriveSuffix() {
        XCTAssertEqual(
            NoteConflictDetector.stripConflictSuffix("Meeting (Mac's conflicted copy 2026-05-18)"),
            "Meeting"
        )
    }

    func testStripsDropboxShortForm() {
        XCTAssertEqual(
            NoteConflictDetector.stripConflictSuffix("Note (conflicted copy)"),
            "Note"
        )
    }

    func testReturnsNilForCleanName() {
        XCTAssertNil(NoteConflictDetector.stripConflictSuffix("Regular note"))
    }

    func testReturnsNilForUnrelatedParenSuffix() {
        XCTAssertNil(NoteConflictDetector.stripConflictSuffix("Meeting (draft)"))
    }

    func testReturnsNilForEmptyOriginal() {
        XCTAssertNil(NoteConflictDetector.stripConflictSuffix("(Mac's conflicted copy 2026-05-18)"))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(
            NoteConflictDetector.stripConflictSuffix("X (CONFLICTED COPY)"),
            "X"
        )
    }

    // MARK: - End-to-end

    func testListConflictsFindsCandidate() throws {
        // Write one clean file and one conflict file directly.
        try fileStore.write(NoteFile(
            id: "clean",
            frontmatter: NoteFrontmatter(title: "Meeting", createdAt: Date(), updatedAt: Date()),
            body: ""
        ))
        // Conflict file lands on disk directly (simulates an iCloud sync).
        let conflictName = "Meeting (Mac's conflicted copy 2026-05-18).md"
        let conflictURL = tempRoot.appendingPathComponent(conflictName)
        try "---\nid: conflict-id\ntitle: Meeting\ncreated: 2026-05-18T10:00:00.000Z\nupdated: 2026-05-18T10:00:00.000Z\nnotebookId:\ntags: []\nisDailyNote: false\ndailyDate:\n---\n\nbody"
            .write(to: conflictURL, atomically: true, encoding: .utf8)

        let matches = try detector.listConflicts()
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.originalName, "Meeting")
        XCTAssertEqual(matches.first?.noteId, "conflict-id")
    }

    func testListConflictsEmptyForCleanVault() throws {
        try fileStore.write(NoteFile(
            id: "a",
            frontmatter: NoteFrontmatter(title: "A", createdAt: Date(), updatedAt: Date()),
            body: ""
        ))
        XCTAssertTrue(try detector.listConflicts().isEmpty)
    }
}
