// ScribeTests/PeopleIndexTests.swift
import XCTest
import GRDB
@testable import Scribe

final class PeopleIndexTests: XCTestCase {

    // MARK: - Normalisation

    func testNormalizedKeyFoldsCaseWhitespaceDiacriticsAndPossessive() {
        XCTAssertEqual(PeopleIndex.normalizedKey("  Alice   SMITH "), "alice smith")
        XCTAssertEqual(PeopleIndex.normalizedKey("José"), "jose")
        XCTAssertEqual(PeopleIndex.normalizedKey("Alice's"), "alice")
        XCTAssertEqual(PeopleIndex.normalizedKey("Bob,"), "bob")
        XCTAssertEqual(PeopleIndex.displayName(" Mary-Jane\tO'Neil "), "Mary-Jane O'Neil")
    }

    func testPlaceholderSpeakersAreNotPeople() {
        for name in ["you", "Remote", "Speaker 2", "guest 10", "42", "", " "] {
            XCTAssertFalse(PeopleIndex.isPlausibleName(name), name)
        }
        for name in ["Alice", "Bob Stone", "Dr. Who"] {
            XCTAssertTrue(PeopleIndex.isPlausibleName(name), name)
        }
    }

    func testFirstNameMergesOnlyWhenUnambiguous() {
        let unique = PeopleIndex.canonicalKeys(for: ["alice", "alice smith", "bob"])
        XCTAssertEqual(unique["alice"], "alice smith")
        XCTAssertEqual(unique["bob"], "bob")

        let ambiguous = PeopleIndex.canonicalKeys(for: ["alice", "alice smith", "alice jones"])
        XCTAssertEqual(ambiguous["alice"], "alice")
        XCTAssertEqual(ambiguous["alice smith"], "alice smith")
        XCTAssertEqual(ambiguous["alice jones"], "alice jones")
    }

    // MARK: - Task matching

    func testTaskMatchesTitleTagAndAssignee() {
        let keys = ["alice smith", "alice"]
        XCTAssertTrue(PeopleIndex.task(PersonTaskRef(id: "1", title: "Send deck to Alice"), mentionsAnyOf: keys))
        XCTAssertTrue(PeopleIndex.task(PersonTaskRef(id: "2", title: "Review", tags: ["@alice-smith"]), mentionsAnyOf: keys))
        XCTAssertTrue(PeopleIndex.task(PersonTaskRef(id: "3", title: "Review", tags: ["alicesmith"]), mentionsAnyOf: keys))
        XCTAssertTrue(PeopleIndex.task(PersonTaskRef(id: "4", title: "Draft", assignee: "Alice Smith"), mentionsAnyOf: keys))
        XCTAssertFalse(PeopleIndex.task(PersonTaskRef(id: "5", title: "Call Alicent"), mentionsAnyOf: keys))
        XCTAssertFalse(PeopleIndex.task(PersonTaskRef(id: "6", title: "Unrelated"), mentionsAnyOf: keys))
    }

    // MARK: - Build (pure)

    func testBuildAggregatesMeetingsAndMergesNames() {
        let d1 = Date(timeIntervalSince1970: 1_000)
        let d2 = Date(timeIntervalSince1970: 2_000)
        let meetings = [
            "s1": PersonMeeting(sessionId: "s1", sessionTitle: "Kickoff", date: d1, noteId: "n1", noteTitle: "Kickoff notes"),
            "s2": PersonMeeting(sessionId: "s2", sessionTitle: "Review", date: d2, noteId: "n2", noteTitle: "Review notes")
        ]
        let mentions = [
            PersonMention(name: "Alice Smith", sessionId: "s1", source: .entity),
            PersonMention(name: "alice", sessionId: "s2", source: .speaker),
            PersonMention(name: "you", sessionId: "s2", source: .speaker),
            PersonMention(name: "Bob", sessionId: "s2", source: .entity),
            PersonMention(name: "Ghost", sessionId: "missing", source: .entity)
        ]
        let tasks = [
            PersonTaskRef(id: "t1", title: "Follow up with Alice on pricing"),
            PersonTaskRef(id: "t2", title: "Bob to fix CI")
        ]
        let people = PeopleIndex.build(mentions: mentions, meetings: meetings, tasks: tasks)

        XCTAssertEqual(people.map(\.name), ["Alice Smith", "Bob"])
        let alice = people[0]
        XCTAssertEqual(alice.id, "alice smith")
        XCTAssertEqual(alice.aliases, ["alice", "alice smith"])
        XCTAssertEqual(alice.meetings.map(\.sessionId), ["s2", "s1"])  // newest first
        XCTAssertEqual(alice.openTasks.map(\.id), ["t1"])
        XCTAssertEqual(people[1].openTasks.map(\.id), ["t2"])
        XCTAssertNil(PeopleIndex.find("ghost", in: people))
        XCTAssertEqual(PeopleIndex.find("ALICE", in: people)?.id, "alice smith")
    }

    func testAmbiguousFirstNameStaysSeparate() {
        let meetings = [
            "s1": PersonMeeting(sessionId: "s1", sessionTitle: "A", date: Date()),
            "s2": PersonMeeting(sessionId: "s2", sessionTitle: "B", date: Date()),
            "s3": PersonMeeting(sessionId: "s3", sessionTitle: "C", date: Date())
        ]
        let mentions = [
            PersonMention(name: "Alice Smith", sessionId: "s1", source: .entity),
            PersonMention(name: "Alice Jones", sessionId: "s2", source: .entity),
            PersonMention(name: "Alice", sessionId: "s3", source: .entity)
        ]
        let people = PeopleIndex.build(mentions: mentions, meetings: meetings,
                                       tasks: [PersonTaskRef(id: "t", title: "Ping Alice")])
        XCTAssertEqual(Set(people.map(\.id)), ["alice smith", "alice jones", "alice"])
        // "Alice" in a task title is ambiguous for the full names, but the
        // lone "Alice" person still matches it.
        XCTAssertEqual(people.first { $0.id == "alice" }?.openTasks.map(\.id), ["t"])
        XCTAssertEqual(people.first { $0.id == "alice smith" }?.openTasks.count, 0)
    }

    // MARK: - Repository (in-memory DB)

    func testRepositoryAggregatesEntitiesSpeakersAssigneesAndTasks() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let transcripts = TranscriptStore(databaseManager: dbm)
        let tasks = TaskStore(databaseManager: dbm)

        let s1 = try TestHelpers.makeBoundSession(title: "Kickoff", notes: notes, transcripts: transcripts,
                                                  noteTitle: "Kickoff notes")
        let s2 = try TestHelpers.makeBoundSession(title: "Retro", notes: notes, transcripts: transcripts,
                                                  noteTitle: "Retro notes")
        try transcripts.saveEntities([
            ExtractedEntity(id: UUID(), text: "Dana Scully", type: .person, range: nil, segmentId: nil),
            ExtractedEntity(id: UUID(), text: "Acme", type: .organization, range: nil, segmentId: nil)
        ], sessionId: s1.id)
        try transcripts.addSegment(sessionId: s2.id, startMs: 0, endMs: 1_000, speaker: "Dana", text: "Hi")
        try transcripts.addSegment(sessionId: s2.id, startMs: 1_000, endMs: 2_000, speaker: "remote", text: "Hello")
        let item = ActionItem(id: UUID(), description: "Write report", assignee: "Fox Mulder",
                              deadline: nil, priority: nil, sourceText: "")
        try transcripts.saveActionItems([item], sessionId: s2.id, summaryId: nil)

        try tasks.createTask(title: "Send notes to Dana")
        try tasks.createTask(title: "Unrelated chore")
        let done = try tasks.createTask(title: "Old thing for Dana")
        try tasks.completeTask(id: done.id)
        try tasks.createTask(title: "Write report", sourceSessionId: s2.id,
                             sourceActionItemId: item.id.uuidString)

        let people = try PeopleRepository(dbManager: dbm).loadPeople()
        XCTAssertEqual(people.map(\.name), ["Dana Scully", "Fox Mulder"])

        let dana = people[0]
        XCTAssertEqual(Set(dana.meetings.map(\.sessionId)), [s1.id, s2.id])
        XCTAssertEqual(Set(dana.meetings.compactMap(\.noteTitle)), ["Kickoff notes", "Retro notes"])
        XCTAssertEqual(dana.openTasks.map(\.title), ["Send notes to Dana"])

        let fox = people[1]
        XCTAssertEqual(fox.openTasks.map(\.title), ["Write report"])

        let found = try PeopleRepository(dbManager: dbm).person(named: "dana")
        XCTAssertEqual(found?.id, "dana scully")
    }
}
