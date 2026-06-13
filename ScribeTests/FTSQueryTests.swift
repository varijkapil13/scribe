// ScribeTests/FTSQueryTests.swift
import XCTest
@testable import Scribe

/// Pins the shared FTS5 escaper's behaviour. Notes, tasks, and the
/// universal transcripts search all funnel through `FTSQuery.escape` —
/// if any of these assertions change, the search semantics for every
/// surface change with them.
final class FTSQueryTests: XCTestCase {

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(FTSQuery.escape(""), "")
        XCTAssertEqual(FTSQuery.escape("   "), "")
    }

    func testSingleAlphanumericTokenIsQuotedWithPrefix() {
        XCTAssertEqual(FTSQuery.escape("budget"), "\"budget\"*")
    }

    func testMultipleTokensJoinedBySpace() {
        XCTAssertEqual(FTSQuery.escape("budget review"), "\"budget\"* \"review\"*")
    }

    func testPunctuationSplitsTokens() {
        // Punctuation (single-quotes, hyphens, periods, underscores) acts as a
        // token boundary — matching FTS5's unicode61 tokenizer — so a query
        // matches the same way the content was indexed.
        XCTAssertEqual(FTSQuery.escape("O'Reilly's"), "\"O\"* \"Reilly\"* \"s\"*")
        XCTAssertEqual(FTSQuery.escape("co-founder"), "\"co\"* \"founder\"*")
        XCTAssertEqual(FTSQuery.escape("to-do"), "\"to\"* \"do\"*")
        XCTAssertEqual(FTSQuery.escape("snake_case"), "\"snake\"* \"case\"*")
    }

    func testPunctuationOnlyInputReturnsEmpty() {
        // Caller is expected to treat "" as "no results" rather than passing
        // it to FTS5, which would otherwise raise a malformed-query error.
        XCTAssertEqual(FTSQuery.escape("---"), "")
        XCTAssertEqual(FTSQuery.escape("???"), "")
        XCTAssertEqual(FTSQuery.escape("- -"), "")
    }

    func testUnicodeAlphanumericsAreKept() {
        // .alphanumerics covers Unicode letters / digits.
        XCTAssertEqual(FTSQuery.escape("café"), "\"café\"*")
        XCTAssertEqual(FTSQuery.escape("日本語"), "\"日本語\"*")
    }

    func testTabsAndNewlinesSplitTokens() {
        XCTAssertEqual(FTSQuery.escape("alpha\tbeta\ngamma"),
                       "\"alpha\"* \"beta\"* \"gamma\"*")
    }

    func testNoteStoreAndTaskStoreDelegateToFTSQuery() {
        // The thin wrappers must produce byte-identical output so callers
        // can switch between them without behavioural drift.
        let input = "review the Q3 budget"
        let expected = FTSQuery.escape(input)
        XCTAssertEqual(NoteStore.ftsQuery(from: input), expected)
        XCTAssertEqual(TaskStore.ftsQuery(from: input), expected)
    }
}
