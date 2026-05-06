import XCTest
@testable import Scribe

final class QuickAddParserTests: XCTestCase {

    func testStripsTagsProjectAndPriority() {
        let parsed = QuickAddParser.parse(
            "Buy milk #shopping +Errands !high",
            detector: nil
        )
        XCTAssertEqual(parsed.title, "Buy milk")
        XCTAssertEqual(parsed.tags, ["shopping"])
        XCTAssertEqual(parsed.projectName, "Errands")
        XCTAssertEqual(parsed.priority, .high)
        XCTAssertNil(parsed.dueAt)
    }

    func testMultipleTagsKeepFirstOccurrenceOrder() {
        let parsed = QuickAddParser.parse(
            "Send doc #work #urgent #work",
            detector: nil
        )
        XCTAssertEqual(parsed.title, "Send doc")
        XCTAssertEqual(parsed.tags, ["work", "urgent"])
    }

    func testPriorityAliasesAccepted() {
        XCTAssertEqual(QuickAddParser.parse("x !h", detector: nil).priority, .high)
        XCTAssertEqual(QuickAddParser.parse("x !med", detector: nil).priority, .medium)
        XCTAssertEqual(QuickAddParser.parse("x !low", detector: nil).priority, .low)
        XCTAssertNil(QuickAddParser.parse("x !weird", detector: nil).priority)
    }

    func testIgnoresHashOrPlusInsideWord() {
        // `#` and `+` only count when they're at a token boundary.
        let parsed = QuickAddParser.parse("Path is foo#bar baz+qux", detector: nil)
        XCTAssertEqual(parsed.title, "Path is foo#bar baz+qux")
        XCTAssertEqual(parsed.tags, [])
    }

    func testParsesAbsoluteDate() throws {
        let detector = try XCTUnwrap(NSDataDetector.scribeDateDetector)
        let parsed = QuickAddParser.parse(
            "Submit invoice on December 1, 2099",
            detector: detector
        )
        let comps = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: try XCTUnwrap(parsed.dueAt))
        XCTAssertEqual(comps.year, 2099)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 1)
        // Date phrase should be removed from the title.
        XCTAssertFalse(parsed.title.contains("December"))
    }

    func testEmptyInputReturnsEmptyTitle() {
        XCTAssertEqual(QuickAddParser.parse("   ", detector: nil).title, "")
    }
}
