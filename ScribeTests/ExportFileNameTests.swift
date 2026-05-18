// ScribeTests/ExportFileNameTests.swift
import XCTest
@testable import Scribe

/// Sanity for the `NSSavePanel` default-name builder. The original logic
/// was a few lines inside `NoteDetailView.exportMarkdown`; lifting it to
/// `ExportFileName` gave us a chance to harden it (trim, collapse dash
/// runs) and assert the rules directly.
final class ExportFileNameTests: XCTestCase {

    func testPlainTitlePassesThrough() {
        XCTAssertEqual(ExportFileName.safe("Q3 review"), "Q3_review")
    }

    func testIllegalCharactersAreReplaced() {
        // Every char in the illegal set must vanish — these are the ones
        // that break either NSSavePanel itself or downstream cross-platform
        // sync.
        XCTAssertEqual(ExportFileName.safe("foo/bar"), "foo-bar")
        XCTAssertEqual(ExportFileName.safe("a:b"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a?b"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a*b"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a|b"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a\"b"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a<b>"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a\\b"), "a-b")
        XCTAssertEqual(ExportFileName.safe("a%b"), "a-b")
    }

    func testAdjacentIllegalCharactersCollapseToSingleDash() {
        // "Q3/?[draft]" → "Q3--[draft]" without collapsing; we want
        // "Q3-[draft]" (well, with brackets stripped to underscores via
        // the space pass — but the key invariant is no double-dash).
        XCTAssertEqual(ExportFileName.safe("Q3/?review"), "Q3-review")
    }

    func testWhitespaceBecomesUnderscore() {
        XCTAssertEqual(ExportFileName.safe("my big note"), "my_big_note")
    }

    func testLeadingAndTrailingDashesAreTrimmed() {
        // "/leading", "trailing/" → no dangling separators in the final
        // filename so opening the export doesn't look broken.
        XCTAssertEqual(ExportFileName.safe("/leading"), "leading")
        XCTAssertEqual(ExportFileName.safe("trailing/"), "trailing")
        XCTAssertEqual(ExportFileName.safe("/wrapped/"), "wrapped")
    }

    func testEmptyTitleFallsBackToDefault() {
        XCTAssertEqual(ExportFileName.safe(""), "Untitled-note")
        XCTAssertEqual(ExportFileName.safe("   "), "Untitled-note",
                       "Whitespace-only is treated as empty.")
    }

    func testAllIllegalReducesToFallback() {
        // Nothing usable left after sanitisation; don't return an empty
        // string to the save panel — that would crash on macOS.
        XCTAssertEqual(ExportFileName.safe("???"), "Untitled-note")
    }

    func testCustomFallback() {
        XCTAssertEqual(ExportFileName.safe("", fallback: "Export"), "Export")
    }
}
