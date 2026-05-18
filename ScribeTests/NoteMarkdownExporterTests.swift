// ScribeTests/NoteMarkdownExporterTests.swift
import XCTest
@testable import Scribe

@MainActor
final class NoteMarkdownExporterTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!

    override func setUp() async throws {
        try await super.setUp()
        dbm = try DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
    }

    override func tearDown() async throws {
        notes = nil
        transcripts = nil
        dbm = nil
        try await super.tearDown()
    }

    func testExportsTitleAndBodyOnly() throws {
        let note = try notes.createNote(title: "Standup", body: "My takeaways")
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("# Standup"))
        XCTAssertTrue(md.contains("My takeaways"))
        XCTAssertFalse(md.contains("Linked recordings"),
                       "No tail when there are no linked sessions")
    }

    func testExportsUntitledFallback() throws {
        let note = try notes.createNote(title: "", body: "")
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("# Untitled note"))
    }

    func testEmitsLinkedRecordingsTailWhenSessionBound() throws {
        let note = try notes.createNote(title: "Team Sync", body: "")
        _ = try transcripts.createSession(title: "Recording 1", noteId: note.id)
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("## Linked recordings"))
        XCTAssertTrue(md.contains("### Recording 1"))
    }

    func testIncludesSummaryActionItemsAndEntitiesWhenPresent() throws {
        let note = try notes.createNote(title: "Project kickoff", body: "")
        let session = try transcripts.createSession(title: "Kickoff", noteId: note.id)

        let actionItem = ActionItem(
            id: UUID(),
            description: "Ship the prototype",
            assignee: "Alice",
            deadline: "Friday",
            priority: nil,
            sourceText: "We agreed to ship the prototype by Friday."
        )
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Discussed scope and risks.",
            keyDecisions: ["Use Swift 6"],
            actionItems: [actionItem],
            keyTopics: ["scope", "risks"],
            followUpQuestions: [],
            createdAt: Date()
        )
        try transcripts.saveSummary(summary)
        try transcripts.saveEntities(
            [ExtractedEntity(id: UUID(),
                             text: "Alice",
                             type: .person,
                             range: nil,
                             segmentId: nil)],
            sessionId: session.id
        )

        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)

        XCTAssertTrue(md.contains("Discussed scope and risks."), "summary text")
        XCTAssertTrue(md.contains("Use Swift 6"), "key decision")
        XCTAssertTrue(md.contains("Ship the prototype"), "action item description")
        XCTAssertTrue(md.contains("Alice"), "assignee")
        XCTAssertTrue(md.contains("Friday"), "deadline")
        XCTAssertTrue(md.contains("scope"), "topic")
        XCTAssertTrue(md.contains("Mentioned"), "entities header")
        XCTAssertTrue(md.contains("People:"), "entity type label")
    }

    func testOrdersSessionsByCreatedAtDesc() throws {
        let note = try notes.createNote(title: "Multi", body: "")
        let earlierSession = Session(
            title: "First",
            createdAt: Date(timeIntervalSinceNow: -120),
            noteId: note.id
        )
        let laterSession = Session(
            title: "Second",
            createdAt: Date(),
            noteId: note.id
        )
        try dbm.database.write {
            try earlierSession.insert($0)
            try laterSession.insert($0)
        }

        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        let firstIdx = md.range(of: "### First")?.lowerBound
        let secondIdx = md.range(of: "### Second")?.lowerBound
        XCTAssertNotNil(firstIdx)
        XCTAssertNotNil(secondIdx)
        // Second was created later, so it should appear before First (desc order).
        XCTAssertLessThan(secondIdx!, firstIdx!)
    }

    func testTrailingNewline() throws {
        let note = try notes.createNote(title: "X", body: "body")
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.hasSuffix("\n"))
        XCTAssertFalse(md.hasSuffix("\n\n\n"))
    }

    // MARK: - Inline escaping (review item #8)

    func testEscapeInlineLeavesPlainTextAlone() {
        XCTAssertEqual(NoteMarkdownExporter.escapeInline("hello world"),
                       "hello world")
        XCTAssertEqual(NoteMarkdownExporter.escapeInline(""),
                       "")
    }

    func testEscapeInlineEscapesMarkdownMetacharacters() {
        // Every char that has structural meaning in CommonMark inline
        // contexts must be backslash-escaped.
        let raw = "*_`[]()#|<>~\\"
        let escaped = NoteMarkdownExporter.escapeInline(raw)
        XCTAssertEqual(escaped, "\\*\\_\\`\\[\\]\\(\\)\\#\\|\\<\\>\\~\\\\")
    }

    func testTitleWithBracketsIsEscaped() throws {
        let note = try notes.createNote(title: "Q3 [draft]", body: "")
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("# Q3 \\[draft\\]"),
                      "Title brackets must be escaped to avoid breaking link parsing. Got: \(md)")
    }

    func testSessionTitleWithBoldMarkersIsEscaped() throws {
        let note = try notes.createNote(title: "N", body: "")
        _ = try transcripts.createSession(title: "**Important**", noteId: note.id)
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("\\*\\*Important\\*\\*"),
                      "Bold markers in session title must be escaped. Got: \(md)")
        XCTAssertFalse(md.contains("**Important**"),
                       "Unescaped bold markers would render as bold instead of literal.")
    }

    func testActionItemDescriptionWithPipesIsEscaped() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)
        let item = ActionItem(
            id: UUID(),
            description: "Diff old | new",
            assignee: "Alice|Bob",
            deadline: "Mon | Tue",
            priority: nil,
            sourceText: ""
        )
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Plain summary text",
            keyDecisions: [],
            actionItems: [item],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try transcripts.saveSummary(summary)

        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("Diff old \\| new"))
        XCTAssertTrue(md.contains("Alice\\|Bob"))
        XCTAssertTrue(md.contains("Mon \\| Tue"))
    }

    func testEntityTextWithBackticksIsEscaped() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)
        try transcripts.saveEntities(
            [ExtractedEntity(id: UUID(),
                             text: "`prod-db-1`",
                             type: .organization,
                             range: nil,
                             segmentId: nil)],
            sessionId: session.id
        )

        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("\\`prod-db-1\\`"),
                      "Backticks in entity text must be escaped — otherwise the entity would render as a code span. Got: \(md)")
    }

    func testSummaryBodyIsEmittedVerbatim() throws {
        // The summary paragraph itself is allowed to contain real markdown
        // (the model emits bullets / bold by design). Only the field-level
        // values (titles, action item parts, entity names) get escaped.
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "**Highlights:** budget *approved*.",
            keyDecisions: [],
            actionItems: [],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try transcripts.saveSummary(summary)
        let md = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts)
        XCTAssertTrue(md.contains("**Highlights:** budget *approved*."),
                      "Summary paragraph stays verbatim. Got: \(md)")
    }
}
