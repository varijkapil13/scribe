import XCTest
import GRDB
@testable import Scribe

/// Pure calendar logic: event matching, meeting-link extraction, note title /
/// header formatting and reminder planning. No EventKit, no permissions.
final class CalendarEventMatcherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_540_000)

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private let alice = CalendarAttendee(name: "Alice", email: "alice@example.com")
    private let bob = CalendarAttendee(name: "Bob", email: "bob@example.com")

    private func event(
        _ id: String,
        start: Double,
        end: Double,
        attendees: [CalendarAttendee] = [],
        notes: String? = nil,
        url: URL? = nil,
        location: String? = nil,
        allDay: Bool = false
    ) -> CalendarEventInfo {
        CalendarEventInfo(
            id: id, title: id, start: at(start), end: at(end),
            attendees: attendees, notes: notes, url: url, location: location, isAllDay: allDay
        )
    }

    // MARK: - Matching

    func testInProgressEventMatches() {
        let sync = event("sync", start: -40, end: 20)
        XCTAssertEqual(CalendarEventMatcher.bestMatch(in: [sync], at: now)?.id, "sync")
    }

    func testEventStartingWithinWindowMatches() {
        let soon = event("soon", start: 10, end: 40)
        XCTAssertEqual(CalendarEventMatcher.bestMatch(in: [soon], at: now)?.id, "soon")
    }

    func testEventJustEndedWithinWindowOfStartMatches() {
        // Started 10 min ago, 5-minute event already over: still within ±15.
        let short = event("short", start: -10, end: -5)
        XCTAssertEqual(CalendarEventMatcher.bestMatch(in: [short], at: now)?.id, "short")
    }

    func testEventsOutsideWindowDoNotMatch() {
        let later = event("later", start: 20, end: 50)
        let earlier = event("earlier", start: -60, end: -30)
        XCTAssertNil(CalendarEventMatcher.bestMatch(in: [later, earlier], at: now))
    }

    func testWindowBoundaryIsInclusive() {
        XCTAssertTrue(CalendarEventMatcher.isCandidate(event("edge", start: 15, end: 45), at: now))
        XCTAssertFalse(CalendarEventMatcher.isCandidate(event("past", start: 15.5, end: 45), at: now))
    }

    func testAllDayEventsAreIgnored() {
        let holiday = event("holiday", start: -600, end: 800, attendees: [alice, bob], allDay: true)
        XCTAssertNil(CalendarEventMatcher.bestMatch(in: [holiday], at: now))
    }

    func testPrefersEventWithMultipleAttendees() {
        let focus = event("focus", start: -5, end: 55)
        let meeting = event("meeting", start: 10, end: 40, attendees: [alice, bob])
        XCTAssertEqual(CalendarEventMatcher.bestMatch(in: [focus, meeting], at: now)?.id, "meeting")
    }

    func testPrefersEventWithMeetingLink() {
        let room = event("room", start: 0, end: 30, attendees: [alice, bob])
        let zoom = event("zoom", start: 10, end: 40, attendees: [alice, bob],
                         url: URL(string: "https://us02web.zoom.us/j/123456789"))
        XCTAssertEqual(CalendarEventMatcher.bestMatch(in: [room, zoom], at: now)?.id, "zoom")
    }

    func testOtherwisePrefersClosestStart() {
        let a = event("a", start: -12, end: 30, attendees: [alice, bob])
        let b = event("b", start: 3, end: 30, attendees: [alice, bob])
        XCTAssertEqual(CalendarEventMatcher.bestMatch(in: [a, b], at: now)?.id, "b")
    }

    func testUpcomingTodayFiltersSortsAndLimits() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // now = 2026-10-09 10:00 UTC
        let events = [
            event("third", start: 120, end: 150),
            event("ended", start: -60, end: -10),
            event("first", start: -10, end: 30),
            event("allday", start: -500, end: 900, allDay: true),
            event("second", start: 60, end: 90),
            event("fourth", start: 180, end: 210),
            event("tomorrow", start: 24 * 60, end: 24 * 60 + 30),
        ]
        let upcoming = CalendarEventMatcher.upcomingToday(events, now: now, limit: 3, calendar: calendar)
        XCTAssertEqual(upcoming.map(\.id), ["first", "second", "third"])
    }

    // MARK: - Meeting links

    func testExtractsLinksForKnownProviders() {
        let cases = [
            "Join: https://us02web.zoom.us/j/8812345678?pwd=abc",
            "https://meet.google.com/abc-defg-hij",
            "Click https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0 to join",
            "Webex https://acme.webex.com/acme/j.php?MTID=m123",
        ]
        for text in cases {
            XCTAssertNotNil(MeetingLinkExtractor.meetingURL(in: text), "No link found in: \(text)")
        }
    }

    func testIgnoresNonMeetingLinks() {
        XCTAssertNil(MeetingLinkExtractor.meetingURL(in: "Agenda: https://docs.example.com/doc/1"))
        XCTAssertNil(MeetingLinkExtractor.meetingURL(in: "Room 4B"))
        XCTAssertNil(MeetingLinkExtractor.meetingURL(in: nil))
        // Look-alike host must not match.
        XCTAssertNil(MeetingLinkExtractor.meetingURL(in: "https://notzoom.us/j/1"))
    }

    func testLinkPriorityIsURLThenNotesThenLocation() {
        let fromURL = MeetingLinkExtractor.meetingURL(
            url: URL(string: "https://meet.google.com/aaa-bbbb-ccc"),
            notes: "https://zoom.us/j/1",
            location: "https://teams.microsoft.com/l/x"
        )
        XCTAssertEqual(fromURL?.host, "meet.google.com")

        let fromNotes = MeetingLinkExtractor.meetingURL(
            url: URL(string: "https://example.com/event"),
            notes: "Dial in: https://zoom.us/j/1",
            location: "https://teams.microsoft.com/l/x"
        )
        XCTAssertEqual(fromNotes?.host, "zoom.us")

        let fromLocation = MeetingLinkExtractor.meetingURL(
            url: nil, notes: "No link here", location: "Microsoft Teams Meeting https://teams.microsoft.com/l/x"
        )
        XCTAssertEqual(fromLocation?.host, "teams.microsoft.com")
    }

    // MARK: - Formatting

    func testNoteTitleFormat() {
        let sync = CalendarEventInfo(id: "1", title: "Weekly Sync", start: now, end: at(30))
        let title = CalendarNoteFormatter.noteTitle(
            for: sync,
            date: now,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(title, "Weekly Sync — Oct 9, 2026")
    }

    func testNoteTitleFallsBackForUntitledEvents() {
        let untitled = CalendarEventInfo(id: "1", title: "  ", start: now, end: at(30))
        let title = CalendarNoteFormatter.noteTitle(
            for: untitled, date: now,
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(title, "Meeting — Oct 9, 2026")
    }

    func testNoteHeaderListsAttendeesAgendaAndLink() {
        let sync = event(
            "sync", start: 0, end: 30,
            attendees: [alice, CalendarAttendee(name: "", email: "carol@example.com")],
            notes: "1. Roadmap\n2. Hiring",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let header = CalendarNoteFormatter.noteHeader(for: sync)
        XCTAssertTrue(header.contains("**Attendees**"))
        XCTAssertTrue(header.contains("- Alice (alice@example.com)"))
        XCTAssertTrue(header.contains("- carol@example.com"))
        XCTAssertTrue(header.contains("**Agenda**\n1. Roadmap\n2. Hiring"))
        XCTAssertTrue(header.contains("https://meet.google.com/abc-defg-hij"))
    }

    func testNoteHeaderEmptyForBareEvent() {
        XCTAssertEqual(CalendarNoteFormatter.noteHeader(for: event("bare", start: 0, end: 30)), "")
    }

    // MARK: - Reminders

    func testReminderPlanOnlyMeetingsWithAttendeesInTheFuture() {
        let events = [
            event("meeting", start: 30, end: 60, attendees: [alice, bob]),
            event("solo", start: 30, end: 60, attendees: [alice]),
            event("allday", start: 30, end: 600, attendees: [alice, bob], allDay: true),
            event("started", start: 0.5, end: 30, attendees: [alice, bob]), // reminder time already passed
        ]
        let plan = CalendarReminderPlanner.plan(events: events, now: now, leadTime: 60)
        XCTAssertEqual(plan.map(\.event.id), ["meeting"])
        XCTAssertEqual(plan.first?.fireDate, at(29))
        XCTAssertEqual(CalendarReminderPlanner.reminderTitle(for: events[0]), "meeting starts in 1 min")
    }

    func testReminderIdentifierIsPerOccurrence() {
        let first = event("weekly", start: 30, end: 60, attendees: [alice, bob])
        let next = event("weekly", start: 30 + 7 * 24 * 60, end: 60 + 7 * 24 * 60, attendees: [alice, bob])
        XCTAssertNotEqual(CalendarReminderPlanner.identifier(for: first),
                          CalendarReminderPlanner.identifier(for: next))
        XCTAssertTrue(CalendarReminderPlanner.identifier(for: first)
            .hasPrefix(CalendarReminderPlanner.identifierPrefix))
    }
}

/// `v17_session_calendar` migration, the Session model round trip, and the
/// calendar-aware note resolution.
@MainActor
final class SessionCalendarMigrationTests: XCTestCase {

    func testV17AddsCalendarColumns() throws {
        let db = try DatabaseManager(path: ":memory:")
        let columns: [String] = try db.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(sessions)")
                .compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("calendarEventId"))
        XCTAssertTrue(columns.contains("calendarEventTitle"))
        XCTAssertTrue(columns.contains("attendees"))
    }

    func testV17KeepsExistingSessionsReadable() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v16_task_tombstones")
        let noteId = UUID().uuidString
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO notes (id, title, createdAt, updatedAt, isDailyNote)
                VALUES (?, 'Note', ?, ?, 0)
                """, arguments: [noteId, Date(), Date()])
            try database.execute(sql: """
                INSERT INTO sessions (id, title, createdAt, tags, noteId)
                VALUES ('legacy', 'Standup', ?, '[]', ?)
                """, arguments: [Date(), noteId])
        }
        try migrator.migrate(queue)

        let session = try queue.read { try Session.fetchOne($0, key: "legacy") }
        XCTAssertEqual(session?.title, "Standup")
        XCTAssertNil(session?.calendarEventId)
        XCTAssertNil(session?.calendarEventTitle)
        XCTAssertEqual(session?.attendees, [])
    }

    func testSessionCalendarFieldsRoundTrip() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let transcripts = TranscriptStore(databaseManager: dbm)
        let session = try TestHelpers.makeBoundSession(title: "Sync", notes: notes, transcripts: transcripts)

        let attendees = [
            CalendarAttendee(name: "Alice", email: "alice@example.com"),
            CalendarAttendee(name: "Bob", email: nil),
        ]
        try transcripts.setCalendarEvent(
            sessionId: session.id, eventId: "EK-1", eventTitle: "Weekly Sync", attendees: attendees
        )

        let fetched = try XCTUnwrap(transcripts.fetchSession(id: session.id))
        XCTAssertEqual(fetched.calendarEventId, "EK-1")
        XCTAssertEqual(fetched.calendarEventTitle, "Weekly Sync")
        XCTAssertEqual(fetched.attendees, attendees)

        // Stored as a JSON array of {name, email}.
        let raw = try dbm.database.read {
            try String.fetchOne($0, sql: "SELECT attendees FROM sessions WHERE id = ?", arguments: [session.id])
        }
        let decoded = try JSONDecoder().decode([CalendarAttendee].self, from: Data(XCTUnwrap(raw).utf8))
        XCTAssertEqual(decoded, attendees)

        // Full-record update keeps the fields.
        var edited = fetched
        edited.title = "Renamed"
        try transcripts.updateSession(edited)
        XCTAssertEqual(try transcripts.fetchSession(id: session.id), edited)

        // Clearing writes NULL.
        try transcripts.setCalendarEvent(sessionId: session.id, eventId: nil, eventTitle: nil, attendees: [])
        let cleared = try XCTUnwrap(transcripts.fetchSession(id: session.id))
        XCTAssertNil(cleared.calendarEventId)
        XCTAssertEqual(cleared.attendees, [])
        let rawCleared = try dbm.database.read {
            try String.fetchOne($0, sql: "SELECT attendees FROM sessions WHERE id = ?", arguments: [session.id])
        }
        XCTAssertNil(rawCleared)
    }

    func testAttendeeListCodecToleratesBadJSON() {
        XCTAssertEqual(CalendarAttendee.decodeList(fromJSON: nil), [])
        XCTAssertEqual(CalendarAttendee.decodeList(fromJSON: "not json"), [])
        XCTAssertNil(CalendarAttendee.encodeList([]))
    }

    func testResolveNoteContextUsesEventTitleAndSeedsBody() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let resolved = try AppDelegate.resolveNoteContext(
            selection: nil,
            noteStore: notes,
            now: Date(),
            meetingName: "Zoom meeting",
            explicitTitle: "Weekly Sync — Oct 9, 2026",
            initialBody: "**Attendees**\n- Alice\n\n---\n\n"
        )
        XCTAssertTrue(resolved.didCreateNote)
        let created = try XCTUnwrap(notes.fetchNote(id: resolved.noteId))
        XCTAssertEqual(created.title, "Weekly Sync — Oct 9, 2026")
        XCTAssertTrue((created.bodyExcerpt ?? "").contains("Alice"), "Got: \(String(describing: created.bodyExcerpt))")
    }

    func testResolveNoteContextIgnoresEventTitleForOpenNote() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let open = try notes.createNote(title: "Open", body: "")
        let resolved = try AppDelegate.resolveNoteContext(
            selection: .note(open.id), noteStore: notes, now: Date(),
            explicitTitle: "Weekly Sync — Oct 9, 2026"
        )
        XCTAssertFalse(resolved.didCreateNote)
        XCTAssertEqual(resolved.noteId, open.id)
    }
}
