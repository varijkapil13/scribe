import XCTest
@testable import Scribe

final class OnboardingGateTests: XCTestCase {

    func testFreshInstallShowsOnboarding() {
        XCTAssertTrue(OnboardingGate.shouldShow(completedVersion: 0, legacyCompleted: false, currentVersion: 2))
    }

    func testLegacyCompletionCountsAsVersionOne() {
        XCTAssertTrue(OnboardingGate.shouldShow(completedVersion: 0, legacyCompleted: true, currentVersion: 2))
        XCTAssertFalse(OnboardingGate.shouldShow(completedVersion: 0, legacyCompleted: true, currentVersion: 1))
    }

    func testCompletedCurrentVersionHidesOnboarding() {
        XCTAssertFalse(OnboardingGate.shouldShow(completedVersion: 2, legacyCompleted: true, currentVersion: 2))
        XCTAssertFalse(OnboardingGate.shouldShow(completedVersion: 3, legacyCompleted: false, currentVersion: 2))
    }

    func testMarkCompletedPersistsAcrossDefaults() throws {
        let suite = "OnboardingGateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(OnboardingGate.shouldShow(defaults: defaults))
        OnboardingGate.markCompleted(defaults: defaults)
        XCTAssertFalse(OnboardingGate.shouldShow(defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: OnboardingGate.completedVersionKey), OnboardingGate.currentVersion)
        XCTAssertTrue(defaults.bool(forKey: OnboardingGate.legacyCompletedKey))
    }

    func testStepsRunInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .permissions, .meetings, .vault, .done])
        XCTAssertTrue(OnboardingStep.welcome.isFirst)
        XCTAssertTrue(OnboardingStep.done.isLast)
        XCTAssertEqual(OnboardingStep.welcome.next, .permissions)
        XCTAssertEqual(OnboardingStep.vault.previous, .meetings)
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertNil(OnboardingStep.welcome.previous)
    }

    func testEveryStepHasCopy() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.body.isEmpty)
            XCTAssertFalse(step.symbol.isEmpty)
        }
    }
}
