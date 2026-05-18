// ScribeTests/UniversalSearchSectionBuilderTests.swift
import XCTest
@testable import Scribe

/// Locks the result-shaping rules previously buried in
/// `UniversalSearchViewModel`'s private async methods: 10-item per-section
/// limit, "(Untitled)" fallback, defensive filter on transcript hits
/// missing a `noteId`, snippet truncation to 80 chars.
final class UniversalSearchSectionBuilderTests: XCTestCase {

    // MARK: - Notes

    func testNotesSectionFallsBackToUntitledLabel() {
        let note = Note(title: "", body: "body")
        let section = UniversalSearchSectionBuilder.notesSection(from: [note])
        XCTAssertEqual(section.results.first?.title, "(Untitled)")
    }

    func testNotesSectionTruncatesSnippetToEightyChars() {
        let body = String(repeating: "a", count: 200)
        let note = Note(title: "T", body: body)
        let section = UniversalSearchSectionBuilder.notesSection(from: [note])
        XCTAssertEqual(section.results.first?.snippet.count, 80)
    }

    func testNotesSectionCapsResultsAtTen() {
        let notes = (0..<25).map { Note(title: "n\($0)", body: "") }
        let section = UniversalSearchSectionBuilder.notesSection(from: notes)
        XCTAssertEqual(section.results.count, 10,
                       "Hard cap keeps the dropdown skimmable.")
    }

    func testNotesSectionRoutesToNoteDestination() {
        let note = Note(title: "T", body: "")
        let section = UniversalSearchSectionBuilder.notesSection(from: [note])
        guard case .note(let id) = section.results.first?.destination else {
            return XCTFail("Notes section should route to .note(id)")
        }
        XCTAssertEqual(id, note.id)
    }

    // MARK: - Tasks

    func testTasksSectionUsesTaskTitleAndCapsToTen() {
        let tasks = (0..<25).map { TodoTask(id: "t\($0)", title: "Task \($0)") }
        let section = UniversalSearchSectionBuilder.tasksSection(from: tasks)
        XCTAssertEqual(section.results.count, 10)
        XCTAssertEqual(section.results.first?.title, "Task 0")
    }

    func testTasksSectionRoutesToTasksAll() {
        let task = TodoTask(id: "t1", title: "T")
        let section = UniversalSearchSectionBuilder.tasksSection(from: [task])
        // Tasks search routes to the .tasks(.all) destination — the
        // detail panel inside that view filters down to the actual hit.
        if case .tasks(let filter) = section.results.first?.destination {
            XCTAssertEqual(filter, .all)
        } else {
            XCTFail("Tasks section should route to .tasks(.all)")
        }
    }

    // MARK: - Transcripts

    func testTranscriptsSectionRoutesToOwningNote() {
        let session = Session(id: "s1", title: "Meeting", noteId: "n1")
        let segment = Segment(sessionId: "s1", startMs: 0, endMs: 1000,
                              speaker: "you", text: "We discussed scope")
        let section = UniversalSearchSectionBuilder.transcriptsSection(
            from: [(session, [segment])]
        )
        XCTAssertEqual(section.results.count, 1)
        if case .note(let id) = section.results.first?.destination {
            XCTAssertEqual(id, "n1",
                           "Transcript hits must route to the owning note, not the (removed) transcript view.")
        } else {
            XCTFail("Transcript hit didn't route to .note(noteId)")
        }
    }

    func testTranscriptsSectionFiltersOutOrphanSessions() {
        // Defence in depth: post-v11 every session has a noteId, but if
        // one survives the filter must drop it so navigation can't break.
        let orphan = Session(id: "s1", title: "Orphan", noteId: nil)
        let bound = Session(id: "s2", title: "Bound", noteId: "n1")
        let segment = Segment(sessionId: "s2", startMs: 0, endMs: 1, speaker: "you", text: "x")
        let section = UniversalSearchSectionBuilder.transcriptsSection(
            from: [(orphan, []), (bound, [segment])]
        )
        XCTAssertEqual(section.results.count, 1)
        XCTAssertEqual(section.results.first?.id, "transcript-s2")
    }

    func testTranscriptsSectionFallsBackToUntitledSession() {
        let session = Session(id: "s1", title: "", noteId: "n1")
        let section = UniversalSearchSectionBuilder.transcriptsSection(
            from: [(session, [])]
        )
        XCTAssertEqual(section.results.first?.title, "Untitled session")
    }

    func testTranscriptsSectionUsesFirstSegmentTextAsSnippet() {
        let session = Session(id: "s1", title: "T", noteId: "n1")
        let first = Segment(sessionId: "s1", startMs: 0, endMs: 1,
                            speaker: "you", text: "first matching utterance")
        let second = Segment(sessionId: "s1", startMs: 1, endMs: 2,
                             speaker: "you", text: "second match")
        let section = UniversalSearchSectionBuilder.transcriptsSection(
            from: [(session, [first, second])]
        )
        XCTAssertEqual(section.results.first?.snippet, "first matching utterance")
    }

    func testTranscriptsSectionEmptyHitsProducesEmptyResults() {
        let section = UniversalSearchSectionBuilder.transcriptsSection(from: [])
        XCTAssertTrue(section.results.isEmpty)
        XCTAssertEqual(section.id, "transcripts",
                       "Empty section still carries its identity so the View can de-dupe correctly.")
    }
}
