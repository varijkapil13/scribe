import XCTest
@testable import Scribe

/// Note inspector statistics: word / character counts and reading time.
final class NoteInspectorTests: XCTestCase {

    func testEmptyBody() {
        let stats = NoteStatistics.compute(body: "")
        XCTAssertEqual(stats.words, 0)
        XCTAssertEqual(stats.characters, 0)
        XCTAssertEqual(stats.readingMinutes, 0)
        XCTAssertEqual(NoteStatistics.readingTimeLabel(minutes: stats.readingMinutes), "—")
    }

    func testCountsWordsIgnoringMarkdownPunctuation() {
        let stats = NoteStatistics.compute(body: "# Title\n\n- [ ] **Buy** milk, eggs.\n> quoted text")
        // Title, Buy, milk, eggs, quoted, text
        XCTAssertEqual(stats.words, 6)
    }

    func testCharactersExcludeNewlines() {
        let stats = NoteStatistics.compute(body: "ab\ncd\r\n")
        XCTAssertEqual(stats.characters, 4)
    }

    func testReadingTimeRoundsUpAndHasAOneMinuteFloor() {
        XCTAssertEqual(NoteStatistics.readingMinutes(forWords: 1), 1)
        XCTAssertEqual(NoteStatistics.readingMinutes(forWords: 200), 1)
        XCTAssertEqual(NoteStatistics.readingMinutes(forWords: 201), 2)
        XCTAssertEqual(NoteStatistics.readingMinutes(forWords: 1000), 5)
        XCTAssertEqual(NoteStatistics.readingTimeLabel(minutes: 3), "3 min")
    }

    func testReadingTimeFromBody() {
        let body = Array(repeating: "word", count: 450).joined(separator: " ")
        let stats = NoteStatistics.compute(body: body)
        XCTAssertEqual(stats.words, 450)
        XCTAssertEqual(stats.readingMinutes, 3)
    }
}
