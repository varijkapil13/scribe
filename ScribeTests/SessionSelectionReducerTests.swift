// ScribeTests/SessionSelectionReducerTests.swift
import XCTest
@testable import Scribe

/// Pins the chip-selection rules `NoteDetailView` relies on. These were
/// previously hand-rolled inside two `.onChange` closures — they're now
/// pure, so we can lock them down here. Each test mirrors a real user
/// motion: open a note, dismiss the auto-section, cascade-delete a
/// recording, etc.
final class SessionSelectionReducerTests: XCTestCase {

    private func session(_ id: String) -> Session {
        Session(id: id, title: id, noteId: "note-1")
    }

    // MARK: - userCollapsedFromTransition

    func testNilSelectionWithSessionsMeansExplicitDismiss() {
        XCTAssertEqual(
            SessionSelectionReducer.userCollapsedFromTransition(
                newSelection: nil, hasSessions: true
            ),
            true
        )
    }

    func testNilSelectionWithEmptySessionsIsNotADismiss() {
        // The list went empty on its own (cascade delete, etc.) — that's
        // not the user collapsing, so don't latch the sticky flag.
        XCTAssertNil(
            SessionSelectionReducer.userCollapsedFromTransition(
                newSelection: nil, hasSessions: false
            )
        )
    }

    func testSelectingASessionClearsTheStickyFlag() {
        XCTAssertEqual(
            SessionSelectionReducer.userCollapsedFromTransition(
                newSelection: "s1", hasSessions: true
            ),
            false
        )
    }

    // MARK: - selection(forNewSessions:current:userExplicitlyCollapsed:)

    func testAutoSelectsMostRecentWhenNothingSelectedYet() {
        // VM emits sessions newest-first; the first is the most-recent.
        let result = SessionSelectionReducer.selection(
            forNewSessions: [session("new"), session("old")],
            currentSelection: nil,
            userExplicitlyCollapsed: false
        )
        XCTAssertEqual(result, "new")
    }

    func testKeepsCurrentSelectionWhenItStillExists() {
        let result = SessionSelectionReducer.selection(
            forNewSessions: [session("new"), session("old")],
            currentSelection: "old",
            userExplicitlyCollapsed: false
        )
        XCTAssertEqual(result, "old",
                       "A still-valid selection should not jump to the newest just because the list updated.")
    }

    func testStaleSelectionFallsBackToMostRecent() {
        // The selected session was just deleted. The user's prior choice
        // is no longer valid, so the next-best is the new most-recent.
        let result = SessionSelectionReducer.selection(
            forNewSessions: [session("survivor")],
            currentSelection: "deleted",
            userExplicitlyCollapsed: false
        )
        XCTAssertEqual(result, "survivor")
    }

    func testStickyCollapseSuppressesAutoExpand() {
        // User explicitly dismissed. A new session arrived; the auto-
        // section must NOT pop open uninvited.
        let result = SessionSelectionReducer.selection(
            forNewSessions: [session("new")],
            currentSelection: nil,
            userExplicitlyCollapsed: true
        )
        XCTAssertNil(result)
    }

    func testStickyCollapseStillClearsStaleSelection() {
        // Edge case: the user had something selected, then explicitly
        // collapsed — but somehow the prior selection is still in the
        // state when the list updates. If the prior selection is gone
        // from the list we must move to the most-recent rather than
        // hold a dangling reference.
        let result = SessionSelectionReducer.selection(
            forNewSessions: [session("a"), session("b")],
            currentSelection: "deleted",
            userExplicitlyCollapsed: true
        )
        XCTAssertEqual(result, "a",
                       "A stale id wins over sticky-collapse — otherwise we render nothing for a deleted chip.")
    }

    func testEmptySessionsClearsSelection() {
        let result = SessionSelectionReducer.selection(
            forNewSessions: [],
            currentSelection: "gone",
            userExplicitlyCollapsed: false
        )
        XCTAssertNil(result)
    }
}
