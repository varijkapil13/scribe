import XCTest
@testable import Scribe

/// Help › Keyboard Shortcuts must not list one combination twice (which would
/// also mean two menu items fight over it).
final class ShortcutReferenceTests: XCTestCase {

    func testNoDuplicateCombinations() {
        var seen: [String: String] = [:]
        for section in ShortcutReferenceCatalog.sections {
            XCTAssertFalse(section.entries.isEmpty, "\(section.title) is empty")
            for entry in section.entries {
                if let other = seen[entry.combination] {
                    XCTFail("\(entry.combination) is used by both “\(other)” and “\(entry.title)”")
                }
                seen[entry.combination] = entry.title
            }
        }
    }

    func testListsTheNewWindowAndInspectorShortcuts() {
        let all = ShortcutReferenceCatalog.sections.flatMap(\.entries)
        XCTAssertEqual(all.first { $0.title == "Open Note in New Window" }?.combination, "⌥⌘O")
        XCTAssertEqual(all.first { $0.title == "Show / Hide Inspector" }?.combination, "⌥⌘I")
        XCTAssertEqual(all.first { $0.title == "Find Previous" }?.combination, "⇧⌘G")
    }
}
