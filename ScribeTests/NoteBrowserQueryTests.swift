// ScribeTests/NoteBrowserQueryTests.swift
import XCTest
@testable import Scribe

/// The iPhone / iPad notes browser's pure list logic.
final class NoteBrowserQueryTests: XCTestCase {

    private func note(_ id: String, title: String, updated: TimeInterval, created: TimeInterval = 0,
                      notebook: String? = nil, daily: String? = nil, excerpt: String? = nil) -> Note {
        Note(id: id, title: title, createdAt: Date(timeIntervalSince1970: created),
             updatedAt: Date(timeIntervalSince1970: updated),
             isDailyNote: daily != nil, dailyDate: daily, notebookId: notebook, bodyExcerpt: excerpt)
    }

    private var sample: [Note] {
        [
            note("a", title: "Alpha", updated: 30, created: 1),
            note("b", title: "beta", updated: 10, created: 3, notebook: "nb"),
            note("c", title: "", updated: 20, created: 2),
            note("d1", title: "Day one", updated: 5, daily: "2026-10-01"),
            note("d2", title: "Day two", updated: 1, daily: "2026-10-02"),
        ]
    }

    func testInboxExcludesFiledAndDailyNotes() {
        let ids = NoteBrowserQuery.notes(sample, for: .inbox, sort: .updated).map(\.id)
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testAllExcludesDailyNotesAndSortsByModified() {
        let ids = NoteBrowserQuery.notes(sample, for: .all, sort: .updated).map(\.id)
        XCTAssertEqual(ids, ["a", "c", "b"])
    }

    func testCreatedAndTitleSorts() {
        XCTAssertEqual(NoteBrowserQuery.notes(sample, for: .all, sort: .created).map(\.id), ["b", "c", "a"])
        // "Untitled" sorts by its display title; comparison is case-insensitive.
        XCTAssertEqual(NoteBrowserQuery.notes(sample, for: .all, sort: .title).map(\.id), ["a", "b", "c"])
    }

    func testDailyShowsNewestDayFirst() {
        let ids = NoteBrowserQuery.notes(sample, for: .daily, sort: .updated).map(\.id)
        XCTAssertEqual(ids, ["d2", "d1"])
    }

    func testNotebookAndTagDestinations() {
        XCTAssertEqual(NoteBrowserQuery.notes(sample, for: .notebook("nb"), sort: .updated).map(\.id), ["b"])
        XCTAssertEqual(NoteBrowserQuery.notes(sample, for: .tag("x"), tagMembers: ["c", "d1"], sort: .updated).map(\.id),
                       ["c", "d1"])
        XCTAssertTrue(NoteBrowserQuery.notes(sample, for: .tag("x"), tagMembers: nil, sort: .updated).isEmpty)
    }

    func testSearchMatchesNarrowTheDestination() {
        let ids = NoteBrowserQuery.notes(sample, for: .inbox, searchMatches: ["b", "c"], sort: .updated).map(\.id)
        XCTAssertEqual(ids, ["c"])
    }

    func testSubstringFallbackSearch() {
        let n = note("x", title: "Café plans", updated: 0, excerpt: "Budget for Q3")
        XCTAssertTrue(NoteBrowserQuery.matches(n, search: "cafe"))
        XCTAssertTrue(NoteBrowserQuery.matches(n, search: "budget"))
        XCTAssertTrue(NoteBrowserQuery.matches(n, search: "  "))
        XCTAssertFalse(NoteBrowserQuery.matches(n, search: "tokyo"))
    }

    func testNewNoteDefaultsFollowTheDestination() {
        XCTAssertEqual(NotesSidebarItem.notebook("nb").notebookIdForNewNotes, "nb")
        XCTAssertNil(NotesSidebarItem.inbox.notebookIdForNewNotes)
        XCTAssertEqual(NotesSidebarItem.tag("work").tagForNewNotes, "work")
        XCTAssertNil(NotesSidebarItem.all.tagForNewNotes)
        XCTAssertNotEqual(NotesSidebarItem.notebook("a").id, NotesSidebarItem.tag("a").id)
    }

    func testUniqueTitle() {
        XCTAssertEqual(NoteBrowserQuery.uniqueTitle("Ideas", existing: ["Other"]), "Ideas")
        XCTAssertEqual(NoteBrowserQuery.uniqueTitle("Ideas", existing: ["ideas", "Ideas 2"]), "Ideas 3")
    }
}
