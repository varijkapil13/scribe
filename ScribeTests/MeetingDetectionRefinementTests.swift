import XCTest
@testable import Scribe

/// Pins the meeting-detection refinements: per-app allow/deny rules, the
/// camera-as-a-signal boost, the "seen apps" history, and the recording
/// disclosure text fallback.
@MainActor
final class MeetingDetectionRefinementTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "MeetingDetectionRefinementTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Allow / deny rules

    func testDisabledCatalogAppNeverMatches() {
        let rules = MeetingAppRules(disabled: ["com.tinyspeck.slackmacgap"])
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.tinyspeck.slackmacgap", rules: rules))
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.tinyspeck.slackmacgap.helper", rules: rules))
        // Other apps unaffected.
        XCTAssertNotNil(MeetingAppCatalog.match(bundleID: "us.zoom.xos", rules: rules))
    }

    func testDisablingClassicTeamsDoesNotDisableNewTeams() {
        let rules = MeetingAppRules(disabled: ["com.microsoft.teams"])
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.microsoft.teams", rules: rules))
        XCTAssertEqual(
            MeetingAppCatalog.match(bundleID: "com.microsoft.teams2.helper", rules: rules)?.bundleID,
            "com.microsoft.teams2"
        )
    }

    func testDisabledBrowserNeverMatches() {
        let rules = MeetingAppRules(disabled: ["com.apple.Safari", "com.apple.WebKit.GPU"])
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.apple.WebKit.GPU", rules: rules))
        XCTAssertNotNil(MeetingAppCatalog.match(bundleID: "com.google.Chrome", rules: rules))
    }

    func testAlwaysCountedAppMatchesWithOtherAppsOff() {
        let rules = MeetingAppRules(alwaysCounted: ["com.example.phone"])
        let app = MeetingAppCatalog.match(
            bundleID: "com.example.phone.helper", includeOtherApps: false, fallbackName: "Phone", rules: rules
        )
        XCTAssertEqual(app, MeetingApp(bundleID: "com.example.phone.helper", name: "Phone", kind: .other))
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.example.other", rules: rules))
    }

    func testDisabledOtherAppIsExcludedEvenWithOtherAppsOn() {
        let rules = MeetingAppRules(disabled: ["com.example.recorder"])
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.example.recorder", includeOtherApps: true, rules: rules))
        XCTAssertNotNil(MeetingAppCatalog.match(bundleID: "com.example.notes", includeOtherApps: true, rules: rules))
    }

    func testIgnoredSystemProcessesCannotBeOptedIn() {
        let rules = MeetingAppRules(alwaysCounted: ["com.apple.corespeechd"])
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.apple.corespeechd", rules: rules))
    }

    func testSetOtherAppTogglesOptInAndBlock() {
        var rules = MeetingAppRules()
        rules.setOtherApp("com.example.a", counted: true, includeOtherApps: false)
        XCTAssertTrue(rules.countsOtherApp("com.example.a", includeOtherApps: false))

        rules.setOtherApp("com.example.a", counted: false, includeOtherApps: false)
        XCTAssertFalse(rules.countsOtherApp("com.example.a", includeOtherApps: false))
        XCTAssertFalse(rules.disabled.contains("com.example.a"), "No block needed with other apps off")

        // With "any other app" on, switching off must block explicitly.
        rules.setOtherApp("com.example.b", counted: false, includeOtherApps: true)
        XCTAssertFalse(rules.countsOtherApp("com.example.b", includeOtherApps: true))
        rules.setOtherApp("com.example.b", counted: true, includeOtherApps: true)
        XCTAssertTrue(rules.countsOtherApp("com.example.b", includeOtherApps: true))
        XCTAssertFalse(rules.disabled.contains("com.example.b"))
    }

    func testSetCatalogAppAffectsAllItsBundleIDs() {
        var rules = MeetingAppRules()
        rules.setCatalogApp(["com.microsoft.teams", "com.microsoft.teams2"], enabled: false)
        XCTAssertEqual(rules.disabled, ["com.microsoft.teams", "com.microsoft.teams2"])
        rules.setCatalogApp(["com.microsoft.teams", "com.microsoft.teams2"], enabled: true)
        XCTAssertTrue(rules.disabled.isEmpty)
    }

    func testRulesRoundTripThroughDefaults() {
        XCTAssertEqual(MeetingAppRules.load(from: defaults), MeetingAppRules())
        let rules = MeetingAppRules(disabled: ["us.zoom.xos"], alwaysCounted: ["com.example.phone"])
        rules.save(to: defaults)
        XCTAssertEqual(MeetingAppRules.load(from: defaults), rules)
    }

    func testCatalogEntriesGroupSharedNames() {
        let teams = MeetingAppCatalog.entries(kind: .conferencing).first { $0.name == "Microsoft Teams" }
        XCTAssertEqual(teams?.bundleIDs, ["com.microsoft.teams", "com.microsoft.teams2"])
        let safari = MeetingAppCatalog.entries(kind: .browser).first { $0.name == "Safari" }
        XCTAssertEqual(safari?.bundleIDs, ["com.apple.Safari", "com.apple.WebKit.GPU"])
        XCTAssertTrue(MeetingAppCatalog.entries(kind: .other).isEmpty)
    }

    // MARK: - Camera signal

    private let chromeSample = MeetingProcessSample(bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper")
    private let otherSample = MeetingProcessSample(bundleID: "com.example.cam", name: "CamApp")
    private let zoom = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .conferencing)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testCameraMakesExcludedBrowserCount() {
        let without = MeetingSignals.activeMeetingApps(
            processes: [chromeSample], includeBrowsers: false, includeOtherApps: false,
            rules: MeetingAppRules(), cameraInUse: false
        )
        XCTAssertTrue(without.isEmpty)

        let withCamera = MeetingSignals.activeMeetingApps(
            processes: [chromeSample], includeBrowsers: false, includeOtherApps: false,
            rules: MeetingAppRules(), cameraInUse: true
        )
        XCTAssertEqual(withCamera.map(\.bundleID), ["com.google.Chrome"])
        XCTAssertEqual(withCamera.first?.kind, .browser)
    }

    func testCameraMakesUnknownAppCount() {
        let apps = MeetingSignals.activeMeetingApps(
            processes: [otherSample], includeBrowsers: true, includeOtherApps: false,
            rules: MeetingAppRules(), cameraInUse: true
        )
        XCTAssertEqual(apps, [MeetingApp(bundleID: "com.example.cam", name: "CamApp", kind: .other)])
    }

    func testCameraNeverOverridesDisabledOrIgnoredApps() {
        let rules = MeetingAppRules(disabled: ["com.google.Chrome"])
        let apps = MeetingSignals.activeMeetingApps(
            processes: [chromeSample, MeetingProcessSample(bundleID: "com.apple.corespeechd")],
            includeBrowsers: true, includeOtherApps: true, rules: rules, cameraInUse: true
        )
        XCTAssertTrue(apps.isEmpty)
    }

    func testCurrentMeetingAppKeepsCountingAfterCameraTurnsOff() {
        let chrome = MeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome", kind: .browser)
        let apps = MeetingSignals.activeMeetingApps(
            processes: [chromeSample], includeBrowsers: false, includeOtherApps: false,
            rules: MeetingAppRules(), cameraInUse: false, currentMeeting: chrome
        )
        XCTAssertEqual(apps, [chrome])
    }

    func testCameraShortensStartDelay() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15, cameraStartDelay: 1)
        XCTAssertNil(policy.update(active: [zoom], now: at(0), cameraInUse: true))
        XCTAssertEqual(policy.update(active: [zoom], now: at(1), cameraInUse: true), .started(zoom))
    }

    func testWithoutCameraStartDelayIsUnchanged() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15, cameraStartDelay: 1)
        XCTAssertNil(policy.update(active: [zoom], now: at(0)))
        XCTAssertNil(policy.update(active: [zoom], now: at(1)))
        XCTAssertNil(policy.update(active: [zoom], now: at(2)))
        XCTAssertEqual(policy.update(active: [zoom], now: at(3)), .started(zoom))
    }

    func testCameraNeverLengthensStartDelay() {
        var policy = MeetingDetectionPolicy(startDelay: 0, endGrace: 15, cameraStartDelay: 1)
        XCTAssertEqual(policy.update(active: [zoom], now: at(0), cameraInUse: true), .started(zoom))
    }

    // MARK: - Seen apps

    func testHistoryRecordsOnlyNonCatalogApps() {
        let merged = MeetingAppHistory.merged([:], with: [
            MeetingProcessSample(bundleID: "us.zoom.xos", name: "zoom.us"),
            MeetingProcessSample(bundleID: "com.apple.corespeechd"),
            MeetingProcessSample(bundleID: "com.example.phone", name: "Phone"),
            MeetingProcessSample(bundleID: ""),
        ])
        XCTAssertEqual(merged, ["com.example.phone": "Phone"])
    }

    func testHistoryReturnsNilWhenNothingNew() {
        let seen = ["com.example.phone": "Phone"]
        XCTAssertNil(MeetingAppHistory.merged(seen, with: [MeetingProcessSample(bundleID: "com.example.phone", name: "Phone")]))
        XCTAssertNil(MeetingAppHistory.merged(seen, with: []))
    }

    func testHistoryUpgradesPlaceholderName() {
        let seen = ["com.example.phone": "com.example.phone"]
        let merged = MeetingAppHistory.merged(seen, with: [MeetingProcessSample(bundleID: "com.example.phone", name: "Phone")])
        XCTAssertEqual(merged, ["com.example.phone": "Phone"])
    }

    func testHistoryPersistsAndForgets() {
        MeetingAppHistory.record([MeetingProcessSample(bundleID: "com.example.phone", name: "Phone")], in: defaults)
        XCTAssertEqual(MeetingAppHistory.load(from: defaults), ["com.example.phone": "Phone"])
        MeetingAppHistory.forget("com.example.phone", in: defaults)
        XCTAssertTrue(MeetingAppHistory.load(from: defaults).isEmpty)
    }

    func testSettingsListIncludesOptedInAppsMissingFromHistory() {
        let apps = MeetingAppsSettingsModel.otherApps(
            seen: ["com.example.b": "Bravo"],
            rules: MeetingAppRules(alwaysCounted: ["com.example.a"])
        )
        XCTAssertEqual(apps.map(\.bundleID), ["com.example.b", "com.example.a"])
    }

    // MARK: - Disclosure

    func testDisclosureFallsBackToDefault() {
        XCTAssertEqual(ConsentDisclosure.text(from: defaults), ConsentDisclosure.defaultText)
        defaults.set("   \n", forKey: ConsentDisclosure.textKey)
        XCTAssertEqual(ConsentDisclosure.text(from: defaults), ConsentDisclosure.defaultText)
        XCTAssertFalse(ConsentDisclosure.defaultText.isEmpty)
        XCTAssertTrue(ConsentDisclosure.defaultText.contains("Scribe"))
    }

    func testDisclosureUsesTrimmedCustomText() {
        defaults.set("  Recording for notes, OK?\n", forKey: ConsentDisclosure.textKey)
        XCTAssertEqual(ConsentDisclosure.text(from: defaults), "Recording for notes, OK?")
    }

    func testCopyOnStartDefaultsOff() {
        XCTAssertFalse(ConsentDisclosure.copiesOnStart(defaults))
        defaults.set(true, forKey: ConsentDisclosure.copyOnStartKey)
        XCTAssertTrue(ConsentDisclosure.copiesOnStart(defaults))
    }
}
