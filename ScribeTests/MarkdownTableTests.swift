// ScribeTests/MarkdownTableTests.swift
import XCTest
@testable import Scribe

final class MarkdownTableTests: XCTestCase {

    func testDetectsSimpleTable() {
        let source = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables.count, 1)
        let t = tables[0]
        XCTAssertEqual(t.columnCount, 2)
        XCTAssertEqual(t.headerRow, 0)
        XCTAssertEqual(t.separatorRow, 1)
        XCTAssertEqual(t.bodyRows, [2])
    }

    func testRequiresSeparatorRowImmediatelyAfterHeader() {
        let source = """
        | A | B |
        | 1 | 2 |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables.count, 0, "No separator row → not a table")
    }

    func testHandlesMultipleTables() {
        let source = """
        | A | B |
        |---|---|
        | 1 | 2 |

        Some prose.

        | X | Y | Z |
        |---|---|---|
        | a | b | c |
        | d | e | f |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].columnCount, 2)
        XCTAssertEqual(tables[1].columnCount, 3)
        XCTAssertEqual(tables[1].bodyRows.count, 2)
    }

    func testComputesColumnWidthsFromContent() {
        let source = """
        | A | Title |
        |---|---|
        | hello | x |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables[0].columnWidths, [5, 5]) // "hello" wins col 1, "Title" wins col 2
    }
}
