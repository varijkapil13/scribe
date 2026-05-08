import XCTest
@testable import Scribe

final class InlineFormatTests: XCTestCase {

    func testWrapsSelectionInMarker() {
        let (text, sel) = InlineMarkerEditor.toggle(in: "hello world", selection: NSRange(location: 0, length: 11), marker: "**")
        XCTAssertEqual(text, "**hello world**")
        XCTAssertEqual(sel, NSRange(location: 0, length: 15))
    }

    func testUnwrapsWhenSelectionIncludesMarkers() {
        let (text, sel) = InlineMarkerEditor.toggle(in: "**hello world**", selection: NSRange(location: 0, length: 15), marker: "**")
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(sel, NSRange(location: 0, length: 11))
    }

    func testUnwrapsWhenSelectionExcludesMarkers() {
        let (text, sel) = InlineMarkerEditor.toggle(in: "**hello world**", selection: NSRange(location: 2, length: 11), marker: "**")
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(sel, NSRange(location: 0, length: 11))
    }

    func testWrapsWithSingleStarMarker() {
        let (text, sel) = InlineMarkerEditor.toggle(in: "word", selection: NSRange(location: 0, length: 4), marker: "*")
        XCTAssertEqual(text, "*word*")
        XCTAssertEqual(sel, NSRange(location: 0, length: 6))
    }

    func testEmptySelectionInsertsMarkerPair() {
        let (text, sel) = InlineMarkerEditor.toggle(in: "hello", selection: NSRange(location: 3, length: 0), marker: "**")
        XCTAssertEqual(text, "hel****lo")
        XCTAssertEqual(sel, NSRange(location: 5, length: 0))
    }

    func testWrapsInMiddleOfLargerString() {
        let (text, sel) = InlineMarkerEditor.toggle(in: "before word after", selection: NSRange(location: 7, length: 4), marker: "`")
        XCTAssertEqual(text, "before `word` after")
        XCTAssertEqual(sel, NSRange(location: 7, length: 6))
    }
}
