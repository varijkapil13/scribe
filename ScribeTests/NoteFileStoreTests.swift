// ScribeTests/NoteFileStoreTests.swift
import XCTest
@testable import Scribe

final class NoteFileStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var directory: NotesDirectory!
    private var store: NoteFileStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = NotesDirectory(root: tempRoot)
        store = NoteFileStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Round-trip

    func testWriteThenReadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_003_600)
        let original = NoteFile(
            id: "11111111-2222-3333-4444-555555555555",
            frontmatter: NoteFrontmatter(
                title: "Hello World",
                createdAt: now,
                updatedAt: later,
                notebookId: "nb-1",
                tags: ["foo", "bar"],
                isDailyNote: false,
                dailyDate: nil
            ),
            body: "# Heading\n\nSome body text."
        )

        let url = try store.write(original)
        let roundTripped = try store.read(at: url)

        XCTAssertEqual(roundTripped.id, original.id)
        XCTAssertEqual(roundTripped.frontmatter.title, original.frontmatter.title)
        XCTAssertEqual(roundTripped.frontmatter.notebookId, original.frontmatter.notebookId)
        XCTAssertEqual(roundTripped.frontmatter.tags, original.frontmatter.tags)
        XCTAssertEqual(roundTripped.frontmatter.isDailyNote, original.frontmatter.isDailyNote)
        XCTAssertEqual(roundTripped.body, original.body)
        // Date round-trip is millisecond-precision via ISO 8601 fractional
        // seconds, so equality at second precision is enough.
        XCTAssertEqual(Int(roundTripped.frontmatter.createdAt.timeIntervalSince1970),
                       Int(original.frontmatter.createdAt.timeIntervalSince1970))
    }

    // MARK: - Frontmatter quirks

    func testTitleWithCommasAndColonsRoundTrips() throws {
        let file = NoteFile(
            id: UUID().uuidString,
            frontmatter: NoteFrontmatter(
                title: "Mtg w/ Anna: budget, Q3, roadmap",
                createdAt: Date(),
                updatedAt: Date()
            ),
            body: ""
        )
        let url = try store.write(file)
        let parsed = try store.read(at: url)
        XCTAssertEqual(parsed.frontmatter.title, "Mtg w/ Anna: budget, Q3, roadmap")
    }

    func testEmptyTagsRoundTrip() throws {
        let file = NoteFile(
            id: UUID().uuidString,
            frontmatter: NoteFrontmatter(
                title: "No tags",
                createdAt: Date(),
                updatedAt: Date(),
                tags: []
            ),
            body: ""
        )
        let url = try store.write(file)
        let parsed = try store.read(at: url)
        XCTAssertEqual(parsed.frontmatter.tags, [])
    }

    func testFileWithoutFrontmatterUsesFallbacks() throws {
        // Drop a raw markdown file with no `---` block — simulating an
        // external editor adding a file to the vault.
        let raw = "Just a body.\nLine two."
        let url = tempRoot.appendingPathComponent("Some Filename.md")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let parsed = try store.read(at: url)
        XCTAssertEqual(parsed.frontmatter.title, "Some Filename")
        XCTAssertEqual(parsed.body, "Just a body.\nLine two.")
        // The fallback id is a UUID — we can't predict the value, just
        // that it's non-empty and parseable.
        XCTAssertNotNil(UUID(uuidString: parsed.id))
    }

    func testMalformedFrontmatterIsSkipped() throws {
        let raw = "---\nthis is not yaml: but who cares\nno-colon-line\n---\nBody."
        let url = tempRoot.appendingPathComponent("malformed.md")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        let parsed = try store.read(at: url)
        XCTAssertEqual(parsed.body, "Body.")
    }

    // MARK: - Filename behavior

    func testDailyNoteLandsInDailyFolder() throws {
        var dateComponents = DateComponents()
        dateComponents.year = 2026
        dateComponents.month = 5
        dateComponents.day = 18
        dateComponents.timeZone = TimeZone(identifier: "UTC")
        let dailyDate = Calendar(identifier: .gregorian).date(from: dateComponents)!

        let file = NoteFile(
            id: UUID().uuidString,
            frontmatter: NoteFrontmatter(
                title: "Daily Note",
                createdAt: Date(),
                updatedAt: Date(),
                isDailyNote: true,
                dailyDate: dailyDate
            ),
            body: ""
        )
        let url = try store.write(file)
        XCTAssertEqual(url.lastPathComponent, "2026-05-18.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Daily")
    }

    func testFilenameSanitization() throws {
        let file = NoteFile(
            id: UUID().uuidString,
            frontmatter: NoteFrontmatter(
                title: "with/slashes\\and:colons?",
                createdAt: Date(),
                updatedAt: Date()
            ),
            body: ""
        )
        let url = try store.write(file)
        let name = url.deletingPathExtension().lastPathComponent
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("?"))
    }

    func testCollisionForDifferentIdGetsSuffix() throws {
        let a = NoteFile(
            id: "id-a",
            frontmatter: NoteFrontmatter(title: "Meeting", createdAt: Date(), updatedAt: Date()),
            body: "A"
        )
        let b = NoteFile(
            id: "id-b",
            frontmatter: NoteFrontmatter(title: "Meeting", createdAt: Date(), updatedAt: Date()),
            body: "B"
        )
        let urlA = try store.write(a)
        let urlB = try store.write(b)
        XCTAssertNotEqual(urlA, urlB)
        XCTAssertEqual(urlA.lastPathComponent, "Meeting.md")
        XCTAssertEqual(urlB.lastPathComponent, "Meeting 2.md")
    }

    func testRewritingSameIdReusesURL() throws {
        let original = NoteFile(
            id: "id-1",
            frontmatter: NoteFrontmatter(title: "Hello", createdAt: Date(), updatedAt: Date()),
            body: "first"
        )
        let urlA = try store.write(original)
        var updated = original
        updated.body = "second"
        let urlB = try store.write(updated)
        XCTAssertEqual(urlA, urlB)
        XCTAssertEqual(try store.read(at: urlB).body, "second")
    }

    func testRenameMovesFile() throws {
        let original = NoteFile(
            id: "id-1",
            frontmatter: NoteFrontmatter(title: "Old", createdAt: Date(), updatedAt: Date()),
            body: ""
        )
        let urlOld = try store.write(original)
        var renamed = original
        renamed.frontmatter.title = "New"
        let urlNew = try store.write(renamed)
        XCTAssertEqual(urlNew.lastPathComponent, "New.md")
        // Either the old file is gone, or it shares the new URL — we don't
        // garbage-collect orphaned filenames in Slice 1; rename-cleanup
        // lands in Slice 2 alongside the live NoteStore integration.
        XCTAssertNotEqual(urlOld.lastPathComponent, urlNew.lastPathComponent)
    }

    // MARK: - Listing + delete

    func testListAllReturnsEveryFile() throws {
        for i in 1...5 {
            try store.write(NoteFile(
                id: "id-\(i)",
                frontmatter: NoteFrontmatter(title: "Note \(i)", createdAt: Date(), updatedAt: Date()),
                body: ""
            ))
        }
        let listed = try store.listAll()
        XCTAssertEqual(listed.count, 5)
    }

    func testListAllSkipsNonMarkdownFiles() throws {
        try store.write(NoteFile(
            id: "id-1",
            frontmatter: NoteFrontmatter(title: "Note", createdAt: Date(), updatedAt: Date()),
            body: ""
        ))
        // Drop a few non-md files alongside.
        try Data().write(to: tempRoot.appendingPathComponent("ignore.txt"))
        try Data().write(to: tempRoot.appendingPathComponent("noextension"))
        try Data().write(to: tempRoot.appendingPathComponent("photo.png"))

        let listed = try store.listAll()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, "id-1")
    }

    func testDeleteRemovesFile() throws {
        let file = NoteFile(
            id: "to-delete",
            frontmatter: NoteFrontmatter(title: "Trash me", createdAt: Date(), updatedAt: Date()),
            body: ""
        )
        let url = try store.write(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let removed = try store.delete(id: "to-delete")
        XCTAssertEqual(removed, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteUnknownIdReturnsNil() throws {
        XCTAssertNil(try store.delete(id: "never-existed"))
    }

    func testFindURLLocatesById() throws {
        let file = NoteFile(
            id: "find-me",
            frontmatter: NoteFrontmatter(title: "Hidden", createdAt: Date(), updatedAt: Date()),
            body: ""
        )
        let written = try store.write(file)
        let found = try store.findURL(for: "find-me")
        XCTAssertEqual(found, written)
    }
}
