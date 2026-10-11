import XCTest
@testable import Scribe

/// When the iPhone / iPad runs speaker diarization right after a recording
/// and when it defers to a background task.
final class MobileDiarizationPolicyTests: XCTestCase {

    private func conditions(
        power: Bool = false,
        battery: Double? = 0.8,
        thermal: ProcessInfo.ThermalState = .nominal,
        lowPower: Bool = false
    ) -> MobileDiarizationConditions {
        MobileDiarizationConditions(isOnExternalPower: power, batteryLevel: battery,
                                    thermalState: thermal, isLowPowerMode: lowPower)
    }

    func testHealthyBatteryRunsNow() {
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: 0.8)), .runNow)
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: 0.31)), .runNow)
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(thermal: .fair)), .runNow)
    }

    func testLowBatteryDefersUnlessCharging() {
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: 0.30)), .deferred(.lowBattery))
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: 0.05)), .deferred(.lowBattery))
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(power: true, battery: 0.05)), .runNow)
    }

    func testUnknownBatteryLevelCountsAsHealthy() {
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: nil)), .runNow)
    }

    func testLowPowerModeDefersOnBatteryOnly() {
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: 0.9, lowPower: true)), .deferred(.lowPowerMode))
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(power: true, battery: 0.9, lowPower: true)), .runNow)
    }

    func testThermalPressureDefersEvenWhenCharging() {
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(thermal: .serious)), .deferred(.thermal))
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(power: true, thermal: .critical)), .deferred(.thermal))
        XCTAssertEqual(MobileDiarizationPolicy.decide(conditions(battery: 0.1, thermal: .serious)), .deferred(.thermal),
                       "thermal wins over battery")
    }

    func testDeferralBackgroundTaskRequirements() {
        XCTAssertTrue(MobileDiarizationDeferral.lowBattery.requiresExternalPower)
        XCTAssertTrue(MobileDiarizationDeferral.lowPowerMode.requiresExternalPower)
        XCTAssertFalse(MobileDiarizationDeferral.thermal.requiresExternalPower)

        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MobileDiarizationPolicy.earliestRetry(for: .thermal, now: now),
                       now.addingTimeInterval(MobileDiarizationPolicy.thermalRetryDelay))
        XCTAssertNil(MobileDiarizationPolicy.earliestRetry(for: .lowBattery, now: now))
        XCTAssertFalse(MobileDiarizationDeferral.thermal.label.isEmpty)
    }

    func testDeviceBatteryLevelMapping() {
        XCTAssertNil(MobileDiarizationPolicy.batteryLevel(fromDeviceLevel: -1))
        XCTAssertNil(MobileDiarizationPolicy.batteryLevel(fromDeviceLevel: .nan))
        XCTAssertEqual(MobileDiarizationPolicy.batteryLevel(fromDeviceLevel: 0.5), 0.5)
        XCTAssertEqual(MobileDiarizationPolicy.batteryLevel(fromDeviceLevel: 1.2), 1)
        XCTAssertEqual(MobileDiarizationPolicy.batteryLevel(fromDeviceLevel: 0), 0)
    }
}
