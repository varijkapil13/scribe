// ScribeTests/PersonNoteContentTests.swift
import XCTest
@testable import Scribe

final class PersonNoteContentTests: XCTestCase {

    private func person(meetings: [PersonMeeting] = [], tasks: [PersonTaskRef] = []) -> Person {
        Person(id: "alice smith", name: "Alice Smith", aliases: ["alice smith"],
               meetings: meetings, openTasks: tasks)
    }

    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Block

    func testAutoBlockLinksMeetingNotesAndListsTasks() {
        let block = PersonNoteContent.autoBlock(for: person(
            meetings: [
                PersonMeeting(sessionId: "s1", sessionTitle: "Kickoff", date: day, noteId: "n1", noteTitle: "Kickoff notes"),
                PersonMeeting(sessionId: "s2", sessionTitle: "Hallway chat", date: day)
            ],
            tasks: [PersonTaskRef(id: "t1", title: "Send deck", dueAt: day)]
        ))
        XCTAssertTrue(block.hasPrefix(PersonNoteContent.startMarker))
        XCTAssertTrue(block.hasSuffix(PersonNoteContent.endMarker))
        XCTAssertTrue(block.contains("- [[Kickoff notes]] · \(MeetingRetrieval.dayString(day))"))
        // No note → plain text, not a dangling wiki-link.
        XCTAssertTrue(block.contains("- Hallway chat · "))
        XCTAssertFalse(block.contains("[[Hallway chat]]"))
        XCTAssertTrue(block.contains("- Send deck · due \(MeetingRetrieval.dayString(day))"))
    }

    func testAutoBlockEmptyStates() {
        let block = PersonNoteContent.autoBlock(for: person())
        XCTAssertTrue(block.contains("_No meetings yet._"))
        XCTAssertTrue(block.contains("_No open tasks._"))
    }

    // MARK: - Upsert

    func testUpsertReplacesOnlyTheDelimitedBlock() {
        let old = PersonNoteContent.autoBlock(for: person())
        let body = "Intro written by me.\n\n" + old + "\n\n## Notes\n\nLikes coffee."
        let fresh = PersonNoteContent.autoBlock(for: person(tasks: [PersonTaskRef(id: "t", title: "Call back")]))

        let updated = PersonNoteContent.upsert(block: fresh, into: body)
        XCTAssertTrue(updated.hasPrefix("Intro written by me.\n\n"))
        XCTAssertTrue(updated.hasSuffix("\n\n## Notes\n\nLikes coffee."))
        XCTAssertTrue(updated.contains("- Call back"))
        XCTAssertFalse(updated.contains("_No open tasks._"))
        XCTAssertEqual(updated.components(separatedBy: PersonNoteContent.startMarker).count, 2)

        // Idempotent.
        XCTAssertEqual(PersonNoteContent.upsert(block: fresh, into: updated), updated)
    }

    func testUpsertAppendsWhenNoBlock() {
        let block = PersonNoteContent.autoBlock(for: person())
        XCTAssertEqual(PersonNoteContent.upsert(block: block, into: "My notes\n\n"), "My notes\n\n" + block + "\n")
        XCTAssertEqual(PersonNoteContent.upsert(block: block, into: "  \n"), block + "\n")
    }

    func testUpsertWithDanglingStartMarkerKeepsUserText() {
        let block = PersonNoteContent.autoBlock(for: person())
        let body = "Top\n" + PersonNoteContent.startMarker + "\nUser text that must survive"
        let updated = PersonNoteContent.upsert(block: block, into: body)
        XCTAssertTrue(updated.contains("User text that must survive"))
        XCTAssertTrue(updated.hasSuffix(block + "\n"))
        XCTAssertEqual(updated.components(separatedBy: PersonNoteContent.startMarker).count, 2)
    }

    // MARK: - Service (vault on a temp dir)

    func testServiceCreatesThenRefreshesWithoutClobberingUserText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbm = try DatabaseManager(path: ":memory:")
        let store = NoteStore(databaseManager: dbm, fileStore: NoteFileStore(directory: NotesDirectory(root: root)))
        let meetingNote = try store.createNote(title: "Kickoff notes", body: "")
        let service = PersonNoteService(noteStore: store)

        let first = person(meetings: [PersonMeeting(sessionId: "s1", sessionTitle: "Kickoff", date: day,
                                                    noteId: meetingNote.id, noteTitle: "Kickoff notes")])
        let created = try service.createOrRefresh(first)
        XCTAssertEqual(created.title, "Alice Smith")
        XCTAssertEqual(try store.tags(for: created.id), ["person"])
        let notebook = try XCTUnwrap(try store.fetchAllNotebooks().first { $0.name == "People" })
        XCTAssertEqual(try store.fetchNote(id: created.id)?.notebookId, notebook.id)
        // The person note links to the meeting → shows as its backlink.
        XCTAssertEqual(try store.backlinks(for: meetingNote.id).map(\.id), [created.id])

        // User edits outside the block.
        var edited = try XCTUnwrap(try store.fetchNote(id: created.id))
        edited.body += "Prefers async updates.\n"
        try store.updateNote(edited, tags: ["person"])

        // Refresh with a new open task.
        var second = first
        second.openTasks = [PersonTaskRef(id: "t1", title: "Share roadmap")]
        let refreshed = try service.createOrRefresh(second)
        XCTAssertEqual(refreshed.id, created.id)
        let body = try XCTUnwrap(try store.fetchNote(id: created.id)?.body)
        XCTAssertTrue(body.contains("Prefers async updates."))
        XCTAssertTrue(body.contains("- Share roadmap"))
        XCTAssertTrue(body.contains("[[Kickoff notes]]"))
        XCTAssertEqual(try service.existingNoteId(for: second), created.id)
        XCTAssertEqual(try store.fetchAllNotebooks().filter { $0.name == "People" }.count, 1)
    }
}
