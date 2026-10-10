import XCTest
import GRDB
@testable import Scribe

/// Pre-meeting brief: candidate scoring / ranking (attendee overlap, same
/// series, title similarity, the "this is the user" filter), aggregation and
/// rendering, plus the database loader.
final class MeetingBriefBuilderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let me = CalendarAttendee(name: "Me Myself", email: "me@x.com")
    private let ana = CalendarAttendee(name: "Ana Lopez", email: "ana@x.com")
    private let ben = CalendarAttendee(name: "Ben Kim", email: "ben@x.com")
    private let zed = CalendarAttendee(name: "Zed Quinn", email: "zed@x.com")

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private var event: CalendarEventInfo {
        CalendarEventInfo(
            id: "evt1",
            title: "Atlas planning",
            start: now.addingTimeInterval(3_600),
            end: now.addingTimeInterval(7_200),
            attendees: [me, ana, ben]
        )
    }

    private func meeting(
        _ id: String,
        title: String,
        daysAgo days: Double,
        eventId: String? = nil,
        attendees: [CalendarAttendee] = [],
        people: Set<String> = [],
        summary: String? = nil,
        items: [String] = [],
        questions: [String] = []
    ) -> MeetingBriefCandidate {
        MeetingBriefCandidate(
            id: id, kind: .meeting, title: title, noteId: "note-\(id)", noteTitle: title,
            date: daysAgo(days), calendarEventId: eventId, attendees: attendees,
            peopleKeys: people, summary: summary, openActionItems: items, openQuestions: questions
        )
    }

    private var candidates: [MeetingBriefCandidate] {
        [
            meeting("c1", title: "Atlas planning", daysAgo: 7, eventId: "evt1", attendees: [me, ana],
                    summary: "We scoped the beta. Dates were tight.",
                    items: ["Send deck — Ana", "Book room"], questions: ["Budget?"]),
            meeting("c2", title: "Dentist", daysAgo: 3, attendees: [me]),
            meeting("c3", title: "Quarterly review", daysAgo: 2, attendees: [me, ana, ben],
                    items: ["send deck — ana", "Hire QA"]),
            meeting("c4", title: "Atlas planning", daysAgo: -1, eventId: "evt1", attendees: [me, ana]),
            meeting("c6", title: "Random", daysAgo: 1, attendees: [me, zed]),
            MeetingBriefCandidate(id: "n1", kind: .note, title: "Atlas planning notes", noteId: "n1",
                                  noteTitle: "Atlas planning notes", date: daysAgo(10)),
        ]
    }

    // MARK: - Titles / keys

    func testTitleTokensAndSimilarity() {
        XCTAssertEqual(MeetingBriefBuilder.titleTokens("Weekly Sync: Project Atlas 2026"), ["project", "atlas"])
        XCTAssertEqual(MeetingBriefBuilder.titleSimilarity("Project Atlas sync", "Atlas project review"), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(MeetingBriefBuilder.titleSimilarity("Weekly sync", "Daily sync"), 0)
        XCTAssertEqual(MeetingBriefBuilder.titleSimilarity("", "Atlas"), 0)
    }

    func testAttendeeKeys() {
        XCTAssertEqual(MeetingBriefBuilder.keys(for: ana), ["ana@x.com", "ana lopez"])
        XCTAssertEqual(MeetingBriefBuilder.keys(for: CalendarAttendee(name: "x@y.com", email: nil)), [])
        XCTAssertEqual(MeetingBriefBuilder.keys(for: CalendarAttendee(name: "Remote", email: nil)), [])
    }

    func testUbiquitousAttendeeIsIgnored() {
        let keys = MeetingBriefBuilder.ubiquitousKeys(in: candidates.filter { $0.date < now })
        XCTAssertTrue(keys.contains("me@x.com"))
        XCTAssertFalse(keys.contains("ana@x.com"))
        // Too few meetings to tell.
        XCTAssertEqual(MeetingBriefBuilder.ubiquitousKeys(in: Array(candidates.prefix(3))), [])
    }

    // MARK: - Ranking

    func testRankingPrefersSameSeriesThenPeopleThenTitle() {
        let ranked = MeetingBriefBuilder.rank(event: event, candidates: candidates, now: now)
        XCTAssertEqual(ranked.map(\.candidate.id), ["c1", "c3", "n1"])
        XCTAssertEqual(ranked.first?.reasons.first, "Same series")
        XCTAssertTrue(ranked.first?.reasons.contains("With Ana") ?? false)
        XCTAssertTrue(ranked[1].reasons.contains("With Ana, Ben"))
        XCTAssertEqual(ranked[2].reasons, ["Similar title"])
    }

    func testUnrelatedAndFutureMeetingsAreExcluded() {
        let ranked = MeetingBriefBuilder.rank(event: event, candidates: candidates, now: now, limit: 10)
        let ids = Set(ranked.map(\.candidate.id))
        XCTAssertFalse(ids.contains("c2"), "Only the user in common")
        XCTAssertFalse(ids.contains("c4"), "In the future")
        XCTAssertFalse(ids.contains("c6"))
    }

    func testPeopleIndexNamesCountAsAttendees() {
        let fromTranscript = meeting("p1", title: "Hallway chat", daysAgo: 1, people: ["ana lopez", "ben kim"])
        let match = MeetingBriefBuilder.score(event: event, candidate: fromTranscript, now: now)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.reasons, ["With Ana, Ben"])
    }

    func testDuplicateNoteIsDropped() {
        var noteCopy = candidates[0]
        noteCopy.id = "dup"
        noteCopy.kind = .note
        let ranked = MeetingBriefBuilder.rank(event: event, candidates: [candidates[0], noteCopy], now: now)
        XCTAssertEqual(ranked.map(\.candidate.id), ["c1"])
    }

    // MARK: - Brief

    func testBuildAggregatesOpenItemsAndRenders() {
        let brief = MeetingBriefBuilder.build(event: event, candidates: candidates, now: now)
        XCTAssertFalse(brief.isEmpty)
        XCTAssertEqual(brief.eventTitle, "Atlas planning")
        XCTAssertEqual(brief.openActionItems, ["Send deck — Ana", "Book room", "Hire QA"])
        XCTAssertEqual(brief.openQuestions, ["Budget?"])
        XCTAssertEqual(brief.lastMeeting?.candidate.id, "c1")

        let day = MeetingRetrieval.dayString(daysAgo(7))
        XCTAssertEqual(brief.headline, "Last: Atlas planning · \(day) · 3 open items")
        XCTAssertEqual(brief.notificationBody,
                       "Last time (\(day)): We scoped the beta.\nOpen: Send deck — Ana (+2 more)")
        XCTAssertTrue(brief.markdown.hasPrefix("## Brief: Atlas planning"))
        XCTAssertTrue(brief.markdown.contains("- [[Atlas planning]] (\(day)) — Same series, With Ana"))
        XCTAssertTrue(brief.markdown.contains("### Last time\nWe scoped the beta. Dates were tight."))
        XCTAssertTrue(brief.markdown.contains("### Open action items\n- [ ] Send deck — Ana"))
    }

    func testEmptyBriefWithoutHistory() {
        let brief = MeetingBriefBuilder.build(event: event, candidates: [], now: now)
        XCTAssertTrue(brief.isEmpty)
        XCTAssertEqual(brief.headline, "")
        XCTAssertEqual(brief.notificationBody, "")
    }

    func testFirstSentenceAndKey() {
        XCTAssertEqual(MeetingBriefBuilder.firstSentence("One. Two.", maxChars: 50), "One.")
        XCTAssertEqual(MeetingBriefBuilder.firstSentence("No end", maxChars: 50), "No end")
        XCTAssertNil(MeetingBriefBuilder.firstSentence("  ", maxChars: 50))
        XCTAssertNil(MeetingBriefBuilder.firstSentence(nil, maxChars: 50))
        XCTAssertEqual(MeetingBriefBuilder.key(for: event), "evt1@\(Int(now.timeIntervalSince1970) + 3_600)")
        XCTAssertEqual(MeetingBriefService.identifier(for: event), "scribe.calendar.brief.evt1@\(Int(now.timeIntervalSince1970) + 3_600)")
        XCTAssertEqual(MeetingBriefService.title(for: event, leadMinutes: 5), "Brief: Atlas planning in 5 min")
    }

    // MARK: - Repository

    func testRepositoryLoadsSessionsSummariesAndOpenItems() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: dbm)
        let past = Session(title: "Atlas planning", createdAt: daysAgo(7), calendarEventId: "evt1",
                           calendarEventTitle: "Atlas planning", attendees: [me, ana])
        let future = Session(title: "Atlas planning", createdAt: now.addingTimeInterval(86_400))
        try dbm.database.write { db in
            try past.insert(db)
            try future.insert(db)
        }
        try transcripts.saveSummary(MeetingSummary(
            id: UUID(), sessionId: past.id, summary: "We scoped the beta.",
            keyDecisions: [], actionItems: [
                ActionItem(id: UUID(), description: "Send deck", assignee: "Ana", deadline: nil, priority: nil, sourceText: "")
            ],
            keyTopics: [], followUpQuestions: ["Budget?"], createdAt: daysAgo(7)
        ))

        let repo = MeetingBriefRepository(dbManager: dbm)
        let loaded = try repo.candidates(for: event, now: now)
        XCTAssertEqual(loaded.map(\.id), [past.id])
        let candidate = try XCTUnwrap(loaded.first)
        XCTAssertEqual(candidate.kind, .meeting)
        XCTAssertEqual(candidate.calendarEventId, "evt1")
        XCTAssertEqual(candidate.attendees, [me, ana])
        XCTAssertEqual(candidate.summary, "We scoped the beta.")
        XCTAssertEqual(candidate.openActionItems, ["Send deck — Ana"])
        XCTAssertEqual(candidate.openQuestions, ["Budget?"])

        let brief = MeetingBriefBuilder.build(event: event, candidates: loaded, now: now)
        XCTAssertEqual(brief.lastMeeting?.candidate.id, past.id)
    }

    func testDecodeStringArray() {
        XCTAssertEqual(MeetingBriefRepository.decodeStringArray("[\"a\",\"b\"]"), ["a", "b"])
        XCTAssertEqual(MeetingBriefRepository.decodeStringArray("nope"), [])
        XCTAssertEqual(MeetingBriefRepository.decodeStringArray(nil), [])
    }
}
