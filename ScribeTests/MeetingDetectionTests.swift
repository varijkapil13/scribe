import XCTest
@testable import Scribe

/// Pins meeting auto-detection's pure parts: which processes count as a
/// meeting (`MeetingAppCatalog`) and how mic-usage samples debounce into
/// started/ended events (`MeetingDetectionPolicy`). CoreAudio polling and
/// notifications are thin shells around these.
@MainActor
final class MeetingDetectionTests: XCTestCase {

    // MARK: - Catalog

    func testKnownConferencingAppMatches() {
        let app = MeetingAppCatalog.match(bundleID: "us.zoom.xos")
        XCTAssertEqual(app, MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .conferencing))
    }

    func testHelperProcessResolvesToLongestPrefix() {
        // Must pick teams2, not the classic com.microsoft.teams prefix.
        let app = MeetingAppCatalog.match(bundleID: "com.microsoft.teams2.helper")
        XCTAssertEqual(app?.bundleID, "com.microsoft.teams2")
        XCTAssertEqual(app?.name, "Microsoft Teams")

        XCTAssertEqual(MeetingAppCatalog.match(bundleID: "com.google.Chrome.helper")?.kind, .browser)
    }

    func testPrefixMatchRequiresDotBoundary() {
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "us.zoom.xosX"))
    }

    func testBrowsersCanBeExcluded() {
        XCTAssertNotNil(MeetingAppCatalog.match(bundleID: "com.google.Chrome", includeBrowsers: true))
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.google.Chrome", includeBrowsers: false))
    }

    func testUnknownAppOnlyMatchesWhenOtherAppsIncluded() {
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.example.recorder"))
        let app = MeetingAppCatalog.match(
            bundleID: "com.example.recorder", includeOtherApps: true, fallbackName: "Recorder"
        )
        XCTAssertEqual(app, MeetingApp(bundleID: "com.example.recorder", name: "Recorder", kind: .other))
    }

    func testSystemSpeechProcessesAreNeverMeetings() {
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "com.apple.corespeechd", includeOtherApps: true))
        XCTAssertNil(MeetingAppCatalog.match(bundleID: "", includeOtherApps: true))
    }

    // MARK: - Policy

    private let zoom = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .conferencing)
    private let teams = MeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", kind: .conferencing)
    private let chrome = MeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome", kind: .browser)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testMeetingStartsOnlyAfterStartDelay() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15)
        XCTAssertNil(policy.update(active: [zoom], now: at(0)))
        XCTAssertNil(policy.update(active: [zoom], now: at(2)))
        XCTAssertEqual(policy.update(active: [zoom], now: at(3)), .started(zoom))
        XCTAssertEqual(policy.current, zoom)
        // No repeat while the call continues — a dismissed prompt stays dismissed.
        XCTAssertNil(policy.update(active: [zoom], now: at(60)))
    }

    func testBriefMicBlipNeverStartsAMeeting() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15)
        XCTAssertNil(policy.update(active: [zoom], now: at(0)))
        XCTAssertNil(policy.update(active: [], now: at(2)))
        XCTAssertNil(policy.update(active: [zoom], now: at(4)))
        XCTAssertNil(policy.update(active: [zoom], now: at(6)))
        XCTAssertEqual(policy.update(active: [zoom], now: at(7)), .started(zoom))
    }

    func testMeetingEndsAfterGracePeriod() {
        var policy = MeetingDetectionPolicy(startDelay: 0, endGrace: 15)
        XCTAssertEqual(policy.update(active: [zoom], now: at(0)), .started(zoom))
        XCTAssertNil(policy.update(active: [], now: at(10)))
        XCTAssertEqual(policy.update(active: [], now: at(15)), .ended(zoom))
        XCTAssertNil(policy.current)
        XCTAssertNil(policy.update(active: [], now: at(100)))
    }

    func testMicReturningWithinGraceKeepsMeetingAlive() {
        var policy = MeetingDetectionPolicy(startDelay: 0, endGrace: 15)
        _ = policy.update(active: [zoom], now: at(0))
        XCTAssertNil(policy.update(active: [], now: at(10)))
        XCTAssertNil(policy.update(active: [zoom], now: at(12)))
        // Grace restarts from the last time the mic was seen.
        XCTAssertNil(policy.update(active: [], now: at(20)))
        XCTAssertEqual(policy.update(active: [], now: at(27)), .ended(zoom))
    }

    func testSwitchingAppsMidMeetingIsTheSameEpisode() {
        var policy = MeetingDetectionPolicy(startDelay: 0, endGrace: 15)
        XCTAssertEqual(policy.update(active: [zoom], now: at(0)), .started(zoom))
        XCTAssertNil(policy.update(active: [teams], now: at(5)))
        XCTAssertEqual(policy.update(active: [], now: at(25)), .ended(zoom))
    }

    func testConferencingAppWinsOverBrowser() {
        XCTAssertEqual(MeetingDetectionPolicy.primary(of: [chrome, zoom]), zoom)
        XCTAssertEqual(MeetingDetectionPolicy.primary(of: [zoom, teams]), teams) // name tie-break
        XCTAssertNil(MeetingDetectionPolicy.primary(of: []))
    }

    func testResetForgetsMeeting() {
        var policy = MeetingDetectionPolicy(startDelay: 0, endGrace: 15)
        _ = policy.update(active: [zoom], now: at(0))
        policy.reset()
        XCTAssertNil(policy.current)
        XCTAssertEqual(policy.update(active: [zoom], now: at(1)), .started(zoom))
    }

    // MARK: - Naming

    func testMeetingPhraseNamesOnlyConferencingApps() {
        XCTAssertEqual(MeetingDetector.meetingPhrase(for: zoom), "Zoom meeting")
        XCTAssertEqual(MeetingDetector.meetingPhrase(for: chrome), "Meeting")
    }

    func testAutoCreatedNoteIsNamedAfterMeeting() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let resolved = try AppDelegate.resolveNoteContext(
            selection: nil, noteStore: notes, now: Date(), meetingName: "Zoom meeting"
        )
        let created = try XCTUnwrap(notes.fetchNote(id: resolved.noteId))
        XCTAssertTrue(created.title.hasPrefix("Zoom meeting on "), "Got: \(created.title)")
    }
}
