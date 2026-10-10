// ScribeTests/MeetingRetrieverTests.swift
import XCTest
import GRDB
@testable import Scribe

/// `MeetingRetriever` against a real (in-memory) database: FTS over
/// transcripts and notes, LIKE over summaries, and scope resolution.
final class MeetingRetrieverTests: XCTestCase {

    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!
    private let now = Date()

    override func setUp() {
        super.setUp()
        dbm = try! DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
    }

    override func tearDown() {
        notes = nil
        transcripts = nil
        dbm = nil
        super.tearDown()
    }

    @discardableResult
    private func meeting(_ title: String,
                         daysAgo: Double,
                         notebookId: String? = nil,
                         lines: [(String, String)]) throws -> (note: Note, session: Session) {
        let note = try notes.createNote(title: title, body: "", notebookId: notebookId)
        let session = Session(title: title,
                              createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                              noteId: note.id)
        try dbm.database.write { try session.insert($0) }
        for (i, line) in lines.enumerated() {
            try transcripts.addSegment(sessionId: session.id, startMs: i * 1_000,
                                       endMs: (i + 1) * 1_000, speaker: line.0, text: line.1)
        }
        return (note, session)
    }

    func testRetrievesTranscriptLinesNotesAndSummaries() throws {
        let sync = try meeting("Weekly Sync", daysAgo: 1, lines: [
            ("Alice", "The launch date moves to March."),
            ("Bob", "Lunch is at noon.")
        ])
        try transcripts.saveSummary(MeetingSummary(
            id: UUID(), sessionId: sync.session.id,
            summary: "Team agreed to move the launch.", keyDecisions: ["Launch in March"],
            actionItems: [], keyTopics: [], followUpQuestions: [], createdAt: now))
        try notes.createNote(title: "Launch checklist", body: "Prepare the launch press kit.")

        let result = try MeetingRetriever(dbManager: dbm).retrieve(question: "When is the launch?", now: now)

        XCTAssertEqual(result.terms, ["launch"])
        let kinds = Set(result.snippets.map(\.kind))
        XCTAssertEqual(kinds, [.transcript, .summary, .note])
        XCTAssertFalse(result.snippets.contains { $0.text.contains("Lunch is at noon") })
        XCTAssertTrue(result.context.contains("[[Weekly Sync]]"))
        XCTAssertTrue(result.context.contains("[[Launch checklist]]"))
        XCTAssertLessThanOrEqual(result.context.count, MeetingRetrieval.defaultBudget)
        let transcript = try XCTUnwrap(result.snippets.first { $0.kind == .transcript })
        XCTAssertEqual(transcript.noteId, sync.note.id)
        XCTAssertEqual(transcript.speaker, "Alice")
    }

    func testLastDaysScopeExcludesOlderMeetings() throws {
        try meeting("Recent", daysAgo: 2, lines: [("Alice", "Budget is approved.")])
        try meeting("Ancient", daysAgo: 60, lines: [("Bob", "Budget is frozen.")])

        let result = try MeetingRetriever(dbManager: dbm)
            .retrieve(question: "budget", scope: .lastDays(7), now: now)
        XCTAssertEqual(Set(result.snippets.compactMap(\.sessionTitle)), ["Recent"])
    }

    func testNotebookScopeIncludesSubNotebooks() throws {
        let parent = try notes.createNotebook(name: "Clients")
        let child = try notes.createNotebook(name: "Acme", parentId: parent.id)
        try meeting("Acme kickoff", daysAgo: 3, notebookId: child.id, lines: [("Alice", "Pricing proposal sent.")])
        try meeting("Internal", daysAgo: 3, lines: [("Bob", "Pricing page redesign.")])

        let result = try MeetingRetriever(dbManager: dbm)
            .retrieve(question: "pricing", scope: .notebook(id: parent.id, name: "Clients"), now: now)
        XCTAssertEqual(Set(result.snippets.compactMap(\.sessionTitle)), ["Acme kickoff"])
    }

    func testPersonScopeUsesMeetingsTheyAppearedIn() throws {
        let withCarol = try meeting("Design review", daysAgo: 1, lines: [("Carol Diaz", "Roadmap needs another pass.")])
        try meeting("Ops sync", daysAgo: 1, lines: [("Bob", "Roadmap for infra.")])
        XCTAssertNotNil(withCarol)

        let result = try MeetingRetriever(dbManager: dbm)
            .retrieve(question: "roadmap", scope: .person(key: "carol diaz", name: "Carol Diaz"), now: now)
        XCTAssertEqual(Set(result.snippets.compactMap(\.sessionTitle)), ["Design review"])
    }

    func testQuestionWithoutTermsFallsBackToRecentMeetings() throws {
        try meeting("Yesterday", daysAgo: 1, lines: [("Alice", "We shipped the beta.")])

        let result = try MeetingRetriever(dbManager: dbm).retrieve(question: "What happened?", now: now)
        XCTAssertTrue(result.terms.isEmpty)
        XCTAssertEqual(result.snippets.first?.sessionTitle, "Yesterday")
        XCTAssertTrue(result.context.contains("We shipped the beta."))
    }
}
