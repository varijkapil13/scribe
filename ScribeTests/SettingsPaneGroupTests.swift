import XCTest
@testable import Scribe

/// Pins the Settings window sidebar structure: every pane is reachable exactly
/// once, in the documented groups.
final class SettingsPaneGroupTests: XCTestCase {

    func testEveryPaneAppearsInExactlyOneGroup() {
        let listed = SettingsPaneGroup.allCases.flatMap(\.panes)
        XCTAssertEqual(listed.count, Set(listed).count, "A pane is listed in more than one group")
        XCTAssertEqual(Set(listed), Set(SettingsPane.allCases), "Every pane must be reachable from the sidebar")
    }

    func testNoGroupIsEmpty() {
        for group in SettingsPaneGroup.allCases {
            XCTAssertFalse(group.panes.isEmpty, "\(group) has no panes")
        }
    }

    func testGroupOrderMatchesSidebarDesign() {
        XCTAssertEqual(
            SettingsPaneGroup.allCases.map(\.title),
            ["General", "Recording", "Intelligence", "Dictation", "Storage & Sync", "Shortcuts", "MCP", "About"]
        )
    }

    func testIntelligenceGroupHoldsTemplatesVocabularyAndHooks() {
        let panes = SettingsPaneGroup.intelligence.panes
        XCTAssertTrue(panes.contains(.templates))
        XCTAssertTrue(panes.contains(.vocabulary))
        XCTAssertTrue(panes.contains(.hooks))
        XCTAssertEqual(SettingsPane.hooks.group, .intelligence)
    }

    func testRecordingGroupHoldsCalendar() {
        XCTAssertEqual(SettingsPane.calendar.group, .recording)
        XCTAssertNotNil(SettingsPaneGroup.recording.header)
    }

    func testPrivacyAndBackupPanesAreReachable() {
        XCTAssertEqual(SettingsPane.privacy.group, .general)
        XCTAssertEqual(SettingsPane.backup.group, .storageSync)
        XCTAssertEqual(SettingsPane.privacy.title, "Privacy")
        XCTAssertEqual(SettingsPane.backup.title, "Backup")
    }

    func testPaneGroupRoundTrips() {
        for pane in SettingsPane.allCases {
            XCTAssertTrue(pane.group.panes.contains(pane))
        }
    }
}
