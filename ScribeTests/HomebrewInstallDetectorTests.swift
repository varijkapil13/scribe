import XCTest
@testable import Scribe

final class HomebrewInstallDetectorTests: XCTestCase {

    private let roots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    private let home = "/Users/alex"

    // MARK: - Locations

    func testInsideCaskroomMatchesOnlyRealPrefixes() {
        XCTAssertTrue(ScribeHomebrewInstallDetector.isInsideCaskroom(
            appPath: "/opt/homebrew/Caskroom/scribe/1.0/Scribe.app", caskroomRoots: roots))
        XCTAssertTrue(ScribeHomebrewInstallDetector.isInsideCaskroom(
            appPath: "/usr/local/Caskroom/scribe/1.0/Scribe.app/", caskroomRoots: roots))
        XCTAssertFalse(ScribeHomebrewInstallDetector.isInsideCaskroom(
            appPath: "/opt/homebrew/CaskroomX/scribe/Scribe.app", caskroomRoots: roots))
        XCTAssertFalse(ScribeHomebrewInstallDetector.isInsideCaskroom(
            appPath: "/Applications/Scribe.app", caskroomRoots: roots))
    }

    func testCaskAppLocations() {
        XCTAssertTrue(ScribeHomebrewInstallDetector.isCaskAppLocation(appPath: "/Applications/Scribe.app", homeDirectory: home))
        XCTAssertTrue(ScribeHomebrewInstallDetector.isCaskAppLocation(appPath: "/Users/alex/Applications/Scribe.app/", homeDirectory: home + "/"))
        XCTAssertFalse(ScribeHomebrewInstallDetector.isCaskAppLocation(
            appPath: "/Users/alex/Library/Developer/Xcode/DerivedData/Scribe/Build/Products/Debug/Scribe.app", homeDirectory: home))
        XCTAssertFalse(ScribeHomebrewInstallDetector.isCaskAppLocation(appPath: "/Applications/Other.app", homeDirectory: home))
    }

    // MARK: - Cask parsing

    func testRubyCaskAutoUpdates() {
        let withFlag = """
        cask "scribe" do
          version "1.2.0"
          auto_updates true
          app "Scribe.app"
        end
        """
        XCTAssertTrue(ScribeHomebrewInstallDetector.caskDeclaresAutoUpdates(withFlag))

        let commented = """
        cask "scribe" do
          # auto_updates true
          app "Scribe.app"
        end
        """
        XCTAssertFalse(ScribeHomebrewInstallDetector.caskDeclaresAutoUpdates(commented))

        XCTAssertFalse(ScribeHomebrewInstallDetector.caskDeclaresAutoUpdates("  auto_updates false\n"))
        XCTAssertTrue(ScribeHomebrewInstallDetector.caskDeclaresAutoUpdates("\tauto_updates true # Sparkle\n"))
    }

    func testJSONCaskAutoUpdates() {
        XCTAssertTrue(ScribeHomebrewInstallDetector.caskDeclaresAutoUpdates(#"{"token":"scribe","auto_updates": true}"#))
        XCTAssertFalse(ScribeHomebrewInstallDetector.caskDeclaresAutoUpdates(#"{"token":"scribe","auto_updates":null}"#))
    }

    func testLatestMetadataFilePrefersNewestTimestampThenJSON() {
        let paths = [
            "1.0.0",
            "1.0.0/20260101120000.000",
            "1.0.0/20260101120000.000/Casks",
            "1.0.0/20260101120000.000/Casks/scribe.rb",
            "1.1.0/20260301090000.000/Casks/scribe.rb",
            "1.1.0/20260301090000.000/Casks/scribe.json",
            "1.1.0/20260301090000.000/Casks/other.rb",
        ]
        XCTAssertEqual(
            ScribeHomebrewInstallDetector.latestMetadataCaskFile(paths),
            "1.1.0/20260301090000.000/Casks/scribe.json"
        )
        XCTAssertNil(ScribeHomebrewInstallDetector.latestMetadataCaskFile(["1.0.0", "1.0.0/x/Casks/other.rb"]))
    }

    // MARK: - Decision

    func testNotHomebrewWithoutCaskroomEntry() {
        let policy = ScribeHomebrewInstallDetector.policy(
            appPath: "/Applications/Scribe.app", homeDirectory: home, caskroomRoots: roots,
            installedCaskDirectory: nil, caskSource: nil
        )
        XCTAssertEqual(policy, .notHomebrew)
    }

    func testDevBuildElsewhereIsNotHomebrewEvenWithCaskInstalled() {
        let policy = ScribeHomebrewInstallDetector.policy(
            appPath: "/Users/alex/src/scribe/build/Scribe.app", homeDirectory: home, caskroomRoots: roots,
            installedCaskDirectory: "/opt/homebrew/Caskroom/scribe", caskSource: "auto_updates true"
        )
        XCTAssertEqual(policy, .notHomebrew)
    }

    func testCaskWithoutAutoUpdatesIsManagedByHomebrew() {
        let policy = ScribeHomebrewInstallDetector.policy(
            appPath: "/Applications/Scribe.app", homeDirectory: home, caskroomRoots: roots,
            installedCaskDirectory: "/opt/homebrew/Caskroom/scribe", caskSource: "cask \"scribe\" do\nend\n"
        )
        XCTAssertEqual(policy, .managedByHomebrew)

        let unreadable = ScribeHomebrewInstallDetector.policy(
            appPath: "/Applications/Scribe.app", homeDirectory: home, caskroomRoots: roots,
            installedCaskDirectory: "/opt/homebrew/Caskroom/scribe", caskSource: nil
        )
        XCTAssertEqual(unreadable, .managedByHomebrew)
    }

    func testCaskWithAutoUpdatesLetsTheAppUpdate() {
        let policy = ScribeHomebrewInstallDetector.policy(
            appPath: "/Applications/Scribe.app", homeDirectory: home, caskroomRoots: roots,
            installedCaskDirectory: "/opt/homebrew/Caskroom/scribe", caskSource: "  auto_updates true\n"
        )
        XCTAssertEqual(policy, .homebrewAllowsAppUpdates)
    }

    func testAppInsideCaskroomCountsAsHomebrew() {
        let policy = ScribeHomebrewInstallDetector.policy(
            appPath: "/opt/homebrew/Caskroom/scribe/1.0/Scribe.app", homeDirectory: home, caskroomRoots: roots,
            installedCaskDirectory: nil, caskSource: nil
        )
        XCTAssertEqual(policy, .managedByHomebrew)
    }

    // MARK: - Updater availability

    private static let feed = "https://github.com/varijkapil13/scribe/releases/latest/download/appcast.xml"

    private func resolve(
        testing: Bool = false,
        linked: Bool = true,
        feed: String? = HomebrewInstallDetectorTests.feed,
        key: String? = "abc123=",
        brew: ScribeHomebrewUpdatePolicy = .notHomebrew
    ) -> ScribeUpdaterAvailability {
        ScribeUpdaterAvailability.resolve(
            isTesting: testing, sparkleLinked: linked, feedURL: feed, publicKey: key, homebrew: brew
        )
    }

    func testUpdaterAvailabilityResolution() {
        XCTAssertEqual(resolve(), .available)
        XCTAssertEqual(resolve(brew: .homebrewAllowsAppUpdates), .available)
        XCTAssertEqual(resolve(brew: .managedByHomebrew), .managedByHomebrew)
        XCTAssertEqual(resolve(testing: true), .disabledForTesting)
        XCTAssertEqual(resolve(linked: false), .notConfigured)
        XCTAssertEqual(resolve(key: ""), .notConfigured)
        XCTAssertEqual(resolve(key: "  "), .notConfigured)
        XCTAssertEqual(resolve(key: nil), .notConfigured)
        XCTAssertEqual(resolve(key: "$(SPARKLE_PUBLIC_ED_KEY)"), .notConfigured)
        XCTAssertEqual(resolve(feed: nil), .notConfigured)
        XCTAssertEqual(resolve(feed: "http://example.com/appcast.xml"), .notConfigured)
    }
}
