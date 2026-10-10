import XCTest
import EventKit
import UserNotifications
@testable import Scribe

final class PrivacyDashboardTests: XCTestCase {

    func testEveryPermissionDeepLinksIntoSystemSettings() {
        for kind in PrivacyPermissionKind.allCases {
            let url = kind.settingsURL
            XCTAssertNotNil(url, "\(kind) has an invalid settings URL")
            XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.purpose.isEmpty)
        }
    }

    func testPrivacyPanesUseTheirAnchors() {
        XCTAssertTrue(PrivacyPermissionKind.microphone.settingsURLString.hasSuffix("?Privacy_Microphone"))
        XCTAssertTrue(PrivacyPermissionKind.screenAndSystemAudio.settingsURLString.hasSuffix("?Privacy_ScreenCapture"))
        XCTAssertTrue(PrivacyPermissionKind.accessibility.settingsURLString.hasSuffix("?Privacy_Accessibility"))
        XCTAssertTrue(PrivacyPermissionKind.calendars.settingsURLString.hasSuffix("?Privacy_Calendars"))
        XCTAssertTrue(PrivacyPermissionKind.reminders.settingsURLString.hasSuffix("?Privacy_Reminders"))
        XCTAssertTrue(PrivacyPermissionKind.speechRecognition.settingsURLString.hasSuffix("?Privacy_SpeechRecognition"))
    }

    func testOnboardingAsksOnlyForCorePermissions() {
        XCTAssertEqual(
            PrivacyPermissionKind.onboardingKinds,
            [.microphone, .screenAndSystemAudio, .speechRecognition, .notifications]
        )
    }

    func testOnlyUndeterminedStatesCanPrompt() {
        XCTAssertTrue(PrivacyPermissionState.notDetermined.canPrompt)
        for state in [PrivacyPermissionState.granted, .limited, .denied, .unknown] {
            XCTAssertFalse(state.canPrompt)
            XCTAssertFalse(state.label.isEmpty)
        }
    }

    func testFrameworkStatusMapping() {
        XCTAssertEqual(PrivacyPermissionProbe.map(EKAuthorizationStatus.fullAccess), .granted)
        XCTAssertEqual(PrivacyPermissionProbe.map(EKAuthorizationStatus.writeOnly), .limited)
        XCTAssertEqual(PrivacyPermissionProbe.map(EKAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PrivacyPermissionProbe.map(EKAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PrivacyPermissionProbe.map(UNAuthorizationStatus.provisional), .limited)
        XCTAssertEqual(PrivacyPermissionProbe.map(UNAuthorizationStatus.authorized), .granted)
    }

    func testDatabaseFileSizeSumsSideFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyDashboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("scribe.db").path
        try Data(count: 100).write(to: URL(fileURLWithPath: db))
        try Data(count: 20).write(to: URL(fileURLWithPath: db + "-wal"))
        XCTAssertEqual(PrivacyDashboardModel.databaseFileSize(atPath: db), 120)
        XCTAssertEqual(PrivacyDashboardModel.databaseFileSize(atPath: dir.appendingPathComponent("none.db").path), 0)
    }
}
