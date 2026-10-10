// ScribeTests/ScribeDeepLinkTests.swift
import XCTest
@testable import Scribe

final class ScribeDeepLinkTests: XCTestCase {

    private func parse(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> ScribeDeepLink? {
        guard let url = URL(string: string) else {
            XCTFail("Invalid test URL: \(string)", file: file, line: line)
            return nil
        }
        return ScribeDeepLink.parse(url)
    }

    // MARK: - Notes

    func testNoteById() {
        XCTAssertEqual(parse("scribe://note/ABC-123"), .note(id: "ABC-123"))
    }

    func testNoteIdKeepsCaseButRouteIsCaseInsensitive() {
        XCTAssertEqual(parse("scribe://NOTE/AbC"), .note(id: "AbC"))
        XCTAssertEqual(parse("SCRIBE://note/AbC"), .note(id: "AbC"))
    }

    func testNoteIdIsPercentDecoded() {
        XCTAssertEqual(parse("scribe://note/a%20b"), .note(id: "a b"))
    }

    func testNoteIdWithEncodedSlashStaysOneSegment() {
        XCTAssertEqual(parse("scribe://note/a%2Fb"), .note(id: "a/b"))
    }

    func testNoteIdWithTrailingSlash() {
        XCTAssertEqual(parse("scribe://note/abc/"), .note(id: "abc"))
    }

    func testNoteWithExtraSegmentsIsRejected() {
        XCTAssertNil(parse("scribe://note/abc/def"))
    }

    func testNoteWithoutIdOrTitleIsRejected() {
        XCTAssertNil(parse("scribe://note"))
        XCTAssertNil(parse("scribe://note/"))
        XCTAssertNil(parse("scribe://note?title="))
        XCTAssertNil(parse("scribe://note?title=%20%20"))
    }

    func testNoteByIdQuery() {
        XCTAssertEqual(parse("scribe://note?id=xyz"), .note(id: "xyz"))
    }

    func testNoteByTitle() {
        XCTAssertEqual(parse("scribe://note?title=Weekly%20Sync"), .noteByTitle("Weekly Sync"))
    }

    func testNoteByTitleDecodesPlusAsSpace() {
        XCTAssertEqual(parse("scribe://note?title=Weekly+Sync"), .noteByTitle("Weekly Sync"))
    }

    func testEncodedPlusIsALiteralPlus() {
        XCTAssertEqual(parse("scribe://note?title=C%2B%2B"), .noteByTitle("C++"))
    }

    func testRouteInPathFormsAreAccepted() {
        XCTAssertEqual(parse("scribe:///note/abc"), .note(id: "abc"))
        XCTAssertEqual(parse("scribe:note/abc"), .note(id: "abc"))
    }

    // MARK: - New note

    func testNewNoteWithTitleAndBody() {
        XCTAssertEqual(
            parse("scribe://new-note?title=Idea&body=Line%201%0ALine%202"),
            .newNote(title: "Idea", body: "Line 1\nLine 2")
        )
    }

    func testNewNoteWithoutParameters() {
        XCTAssertEqual(parse("scribe://new-note"), .newNote(title: nil, body: nil))
    }

    func testNewNoteBlankValuesAreNil() {
        XCTAssertEqual(parse("scribe://new-note?title=&body=%20"), .newNote(title: nil, body: nil))
    }

    func testNewNoteBodyKeepsInnerWhitespace() {
        XCTAssertEqual(
            parse("scribe://new-note?body=%20%20indented"),
            .newNote(title: nil, body: "  indented")
        )
    }

    func testQueryKeysAreCaseInsensitiveAndFirstWins() {
        XCTAssertEqual(
            parse("scribe://new-note?Title=First&title=Second"),
            .newNote(title: "First", body: nil)
        )
    }

    func testNewNoteWithPathSegmentIsRejected() {
        XCTAssertNil(parse("scribe://new-note/extra"))
    }

    // MARK: - Tasks

    func testTaskById() {
        XCTAssertEqual(parse("scribe://task/t-1"), .task(id: "t-1"))
        XCTAssertEqual(parse("scribe://task?id=t-1"), .task(id: "t-1"))
    }

    func testTaskWithoutIdIsRejected() {
        XCTAssertNil(parse("scribe://task"))
        XCTAssertNil(parse("scribe://task/a/b"))
    }

    func testNewTask() {
        XCTAssertEqual(
            parse("scribe://new-task?title=Call%20Sam&due=2026-10-12"),
            .newTask(title: "Call Sam", due: "2026-10-12")
        )
        XCTAssertEqual(parse("scribe://new-task?title=Call+Sam"), .newTask(title: "Call Sam", due: nil))
    }

    func testNewTaskRequiresTitle() {
        XCTAssertNil(parse("scribe://new-task"))
        XCTAssertNil(parse("scribe://new-task?due=today"))
        XCTAssertNil(parse("scribe://new-task?title=%20"))
    }

    // MARK: - Meetings, recording, dictation

    func testMeeting() {
        XCTAssertEqual(parse("scribe://meeting/s-42"), .meeting(sessionId: "s-42"))
        XCTAssertEqual(parse("scribe://session/s-42"), .meeting(sessionId: "s-42"))
        XCTAssertNil(parse("scribe://meeting"))
    }

    func testRecordStartStop() {
        XCTAssertEqual(parse("scribe://record/start"), .startRecording)
        XCTAssertEqual(parse("scribe://record/stop"), .stopRecording)
        XCTAssertEqual(parse("scribe://record/START"), .startRecording)
    }

    func testRecordRejectsUnknownOrMissingVerb() {
        XCTAssertNil(parse("scribe://record"))
        XCTAssertNil(parse("scribe://record/pause"))
        XCTAssertNil(parse("scribe://record/start/now"))
    }

    func testDictate() {
        XCTAssertEqual(parse("scribe://dictate"), .dictate)
        XCTAssertNil(parse("scribe://dictate/now"))
    }

    // MARK: - Search, today

    func testSearch() {
        XCTAssertEqual(parse("scribe://search?q=road%20map"), .search(query: "road map"))
        XCTAssertEqual(parse("scribe://search?query=roadmap"), .search(query: "roadmap"))
    }

    func testSearchWithoutQueryOpensEmptySearch() {
        XCTAssertEqual(parse("scribe://search"), .search(query: ""))
    }

    func testToday() {
        XCTAssertEqual(parse("scribe://today"), .today)
        XCTAssertEqual(parse("scribe://today/"), .today)
    }

    // MARK: - Rejections

    func testOtherSchemesAreRejected() {
        XCTAssertNil(parse("https://note/abc"))
        XCTAssertNil(parse("scribes://note/abc"))
        XCTAssertNil(ScribeDeepLink.parse(URL(fileURLWithPath: "/tmp/note.md")))
    }

    func testUnknownRouteIsRejected() {
        XCTAssertNil(parse("scribe://settings"))
        XCTAssertNil(parse("scribe://bogus/thing"))
    }

    // MARK: - Building / round trips

    func testNoteURL() {
        XCTAssertEqual(ScribeDeepLink.noteURL(id: "ABC-123")?.absoluteString, "scribe://note/ABC-123")
    }

    func testNoteURLEncodesUnsafeCharacters() {
        let url = ScribeDeepLink.noteURL(id: "a b/c")
        XCTAssertEqual(url?.absoluteString, "scribe://note/a%20b%2Fc")
        XCTAssertEqual(url.flatMap(ScribeDeepLink.parse), .note(id: "a b/c"))
    }

    func testEveryCaseRoundTrips() {
        let links: [ScribeDeepLink] = [
            .note(id: "n-1"),
            .noteByTitle("Plans & Ideas = 1+1"),
            .newNote(title: "Idea", body: "Line 1\nLine 2 & more"),
            .newNote(title: nil, body: nil),
            .task(id: "t-1"),
            .newTask(title: "Call Sam", due: "tomorrow"),
            .newTask(title: "Pay rent", due: nil),
            .meeting(sessionId: "s-1"),
            .startRecording,
            .stopRecording,
            .dictate,
            .search(query: "road map"),
            .today,
        ]
        for link in links {
            guard let url = link.url else {
                XCTFail("No URL for \(link)")
                continue
            }
            XCTAssertEqual(ScribeDeepLink.parse(url), link, "Round trip failed for \(url.absoluteString)")
        }
    }

    func testUnicodeRoundTrips() {
        let link = ScribeDeepLink.noteByTitle("Café ☕️ Notes")
        XCTAssertEqual(link.url.flatMap(ScribeDeepLink.parse), link)
    }

    // MARK: - Due dates

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    /// 2026-10-10 15:30:00 UTC
    private let now = Date(timeIntervalSince1970: 1_791_646_200)

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date? {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    func testDueToday() {
        XCTAssertEqual(ScribeDeepLink.dueDate(from: "today", now: now, calendar: utcCalendar), utcDate(2026, 10, 10))
        XCTAssertEqual(ScribeDeepLink.dueDate(from: " Today ", now: now, calendar: utcCalendar), utcDate(2026, 10, 10))
    }

    func testDueTomorrow() {
        XCTAssertEqual(ScribeDeepLink.dueDate(from: "tomorrow", now: now, calendar: utcCalendar), utcDate(2026, 10, 11))
    }

    func testDueCalendarDay() {
        XCTAssertEqual(ScribeDeepLink.dueDate(from: "2026-12-01", now: now, calendar: utcCalendar), utcDate(2026, 12, 1))
    }

    func testDueRejectsImpossibleDay() {
        XCTAssertNil(ScribeDeepLink.dueDate(from: "2026-02-31", now: now, calendar: utcCalendar))
        XCTAssertNil(ScribeDeepLink.dueDate(from: "2026-13-01", now: now, calendar: utcCalendar))
        XCTAssertNil(ScribeDeepLink.dueDate(from: "26-1-1", now: now, calendar: utcCalendar))
    }

    func testDueISODateTime() {
        XCTAssertEqual(
            ScribeDeepLink.dueDate(from: "2026-10-12T17:00:00Z", now: now, calendar: utcCalendar),
            utcDate(2026, 10, 12, 17, 0)
        )
        XCTAssertEqual(
            ScribeDeepLink.dueDate(from: "2026-10-12T19:00:00+02:00", now: now, calendar: utcCalendar),
            utcDate(2026, 10, 12, 17, 0)
        )
    }

    func testDueUnrecognisedReturnsNil() {
        XCTAssertNil(ScribeDeepLink.dueDate(from: "next friday", now: now, calendar: utcCalendar))
        XCTAssertNil(ScribeDeepLink.dueDate(from: "", now: now, calendar: utcCalendar))
    }
}
