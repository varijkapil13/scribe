import XCTest
@testable import Scribe

final class ScribeBackupSettingsTests: XCTestCase {

    func testExportKeepsAppPreferencesAndDropsSystemKeys() {
        let exported = ScribeBackupSettings.exportable(from: [
            "selectedLanguage": "en-US",
            "autoSummarize": true,
            "audioRetentionPolicy": "30",
            "NSWindow Frame main": "0 0 100 100",
            "AppleLanguages": ["en"],
            "com.apple.something": 1,
            "_private": 1,
        ])
        XCTAssertEqual(Set(exported.keys), ["selectedLanguage", "autoSummarize", "audioRetentionPolicy"])
    }

    func testExportDropsMachineSpecificAndSensitiveKeys() {
        let exported = ScribeBackupSettings.exportable(from: [
            "notesVaultPath": "/Users/me/Notes",
            "storageLocation": "/Volumes/Disk",
            "postMeetingHooksEnabled": true,
            "postMeetingHookPaths": ["/usr/local/bin/hook"],
            "mcpEnabled": true,
            "mcpPort": 3333,
            "editor.plantUMLRemoteRendering": true,
            "iCloudSyncEnabled": true,
            "backup.autoFolderPath": "/Volumes/Backup",
            "onboarding.completedVersion": 2,
            "hasCompletedOnboarding": true,
            "dictationMode": "toggle",
        ])
        XCTAssertEqual(Array(exported.keys), ["dictationMode"])
    }

    func testExportDropsValuesThatArentPropertyLists() {
        let exported = ScribeBackupSettings.exportable(from: [
            "ok": "fine",
            "notPlist": NSObject(),
        ])
        XCTAssertEqual(Array(exported.keys), ["ok"])
    }

    func testEncodeDecodeRoundTripReappliesFilter() throws {
        // A hand-edited backup can't sneak excluded keys back in.
        let data = try ScribeBackupSettings.encode([
            "selectedLanguage": "de-DE",
            "mcpEnabled": true,
            "postMeetingHookPaths": ["/tmp/evil"],
        ])
        let restored = try ScribeBackupSettings.decodeRestorable(data)
        XCTAssertEqual(Set(restored.keys), ["selectedLanguage"])
        XCTAssertEqual(restored["selectedLanguage"] as? String, "de-DE")
    }

    func testDecodeRejectsNonDictionaryPlists() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        XCTAssertThrowsError(try ScribeBackupSettings.decodeRestorable(data))
    }

    func testApplyWritesOnlyRestorableKeys() throws {
        let suite = "ScribeBackupSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let data = try ScribeBackupSettings.encode([
            "selectedLanguage": "fr-FR",
            "notesVaultPath": "/elsewhere",
        ])
        let applied = try ScribeBackupSettings.apply(data, to: defaults)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(defaults.string(forKey: "selectedLanguage"), "fr-FR")
        XCTAssertNil(defaults.string(forKey: "notesVaultPath"))
    }

    /// The literals in `excludedKeys` must track the constants the app uses.
    @MainActor
    func testExcludedKeysMatchAppConstants() {
        let constants = [
            NotesDirectory.userPreferenceKey,
            SessionAudioStorage.storageLocationKey,
            MeetingHookSettings.enabledKey,
            MeetingHookSettings.pathsKey,
            PlantUMLRenderingPreference.remoteEnabledKey,
            SpeakerDiarizationSettings.allowModelDownloadKey,
            CloudKitSyncService.enabledDefaultsKey,
            OnboardingGate.legacyCompletedKey,
        ]
        for key in constants {
            XCTAssertFalse(ScribeBackupSettings.isIncluded(key: key), "\(key) must not be exported")
        }
        XCTAssertFalse(ScribeBackupSettings.isIncluded(key: OnboardingGate.completedVersionKey))
        XCTAssertFalse(ScribeBackupSettings.isIncluded(key: ScribeBackupPreferences.autoFolderKey))
        XCTAssertTrue(ScribeBackupSettings.isIncluded(key: AudioRetentionPolicy.defaultsKey))
        XCTAssertTrue(ScribeBackupSettings.isIncluded(key: MeetingDetectionMode.defaultsKey))
    }
}
