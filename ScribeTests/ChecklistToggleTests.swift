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
}
