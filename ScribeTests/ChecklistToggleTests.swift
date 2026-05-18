// ScribeTests/ChecklistToggleTests.swift
import XCTest
@testable import Scribe

final class ChecklistToggleTests: XCTestCase {

    func testToggleUncheckedToChecked() {
        let source = "- [ ] buy milk"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "- [x] buy milk")
    }

    func testToggleCheckedToUnchecked() {
        let source = "- [x] buy milk"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "- [ ] buy milk")
    }

    func testToggleNormalisesCapitalXToLowercase() {
        let source = "- [X] buy milk"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "- [ ] buy milk")
    }

    func testToggleOnlyLineContainingLocation() {
        let source = "- [ ] first\n- [ ] second"
        // Location 12 is inside "- [ ] second".
        let result = ChecklistToggle.toggle(source: source, atLocation: 12)
        XCTAssertEqual(result, "- [ ] first\n- [x] second")
    }

    func testToggleReturnsNilForNonChecklistLine() {
        let source = "plain text"
        XCTAssertNil(ChecklistToggle.toggle(source: source, atLocation: 0))
    }

    func testToggleHandlesIndentedChecklist() {
        let source = "  - [ ] nested"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "  - [x] nested")
    }

    // MARK: - toggleListMarker (toolbar / ⌘⇧U)

    func testToggleListMarkerAddsCheckboxToPlainLine() {
        let (newSource, cursor) = ChecklistToggle.toggleListMarker(
            source: "buy milk",
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(newSource, "- [ ] buy milk")
        XCTAssertEqual(cursor, 6, "Cursor should advance past the inserted marker.")
    }

    func testToggleListMarkerRemovesCheckboxFromUncheckedLine() {
        // Bidirectional: a second invocation must remove the marker
        // (review item #6 — toolbar was previously a no-op).
        let (newSource, _) = ChecklistToggle.toggleListMarker(
            source: "- [ ] buy milk",
            selection: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(newSource, "buy milk")
    }

    func testToggleListMarkerRemovesCheckboxFromCheckedLine() {
        let (newSource, _) = ChecklistToggle.toggleListMarker(
            source: "- [x] buy milk",
            selection: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(newSource, "buy milk")
    }

    func testToggleListMarkerHandlesCapitalXMarker() {
        let (newSource, _) = ChecklistToggle.toggleListMarker(
            source: "- [X] buy milk",
            selection: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(newSource, "buy milk")
    }

    func testToggleListMarkerPreservesIndentWhenRemoving() {
        let (newSource, _) = ChecklistToggle.toggleListMarker(
            source: "  - [ ] nested",
            selection: NSRange(location: 8, length: 0)
        )
        XCTAssertEqual(newSource, "  nested",
                       "Removing the marker keeps the indent it was nested under.")
    }

    func testToggleListMarkerOnlyTouchesTheLineContainingSelection() {
        let source = "alpha\nbeta"
        // Location 6 is inside "beta" — must not flip "alpha".
        let (newSource, _) = ChecklistToggle.toggleListMarker(
            source: source,
            selection: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(newSource, "alpha\n- [ ] beta")
    }

    func testToggleListMarkerCursorClampedAtLineStartOnRemoval() {
        // Cursor was at the very first column of the indented marker — after
        // removal we shouldn't underflow into the prior line.
        let (newSource, cursor) = ChecklistToggle.toggleListMarker(
            source: "  - [ ] nested",
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(newSource, "  nested")
        XCTAssertEqual(cursor, 0)
    }
}
