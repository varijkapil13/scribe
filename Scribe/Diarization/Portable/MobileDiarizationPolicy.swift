import Foundation

// MARK: - When the iPhone / iPad runs speaker diarization (portable)
//
// Diarization is a burst of Neural Engine / CPU work over the whole
// recording. On a phone it runs right after a recording only when that's
// cheap for the user: on power, or with a healthy battery, and never while
// the device is already hot. Otherwise the job waits for a
// `BGProcessingTask` (ScribeiOS/Diarization/IOSDiarizationScheduler), which
// iOS runs later — typically overnight on the charger.
//
// Pure value logic so the macOS `swift test` job covers it.

/// A snapshot of the device's power and thermal state.
struct MobileDiarizationConditions: Equatable, Sendable {
    /// Plugged in (charging, or full on the charger).
    var isOnExternalPower: Bool
    /// 0…1, or nil when unknown (the Simulator, battery monitoring off).
    var batteryLevel: Double?
    var thermalState: ProcessInfo.ThermalState
    var isLowPowerMode: Bool

    nonisolated init(
        isOnExternalPower: Bool,
        batteryLevel: Double?,
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool
    ) {
        self.isOnExternalPower = isOnExternalPower
        self.batteryLevel = batteryLevel
        self.thermalState = thermalState
        self.isLowPowerMode = isLowPowerMode
    }
}

/// Why a job waits.
enum MobileDiarizationDeferral: Equatable, Sendable {
    /// Thermal state `.serious` / `.critical`.
    case thermal
    /// On battery at or below ``MobileDiarizationPolicy/minimumBatteryLevel``.
    case lowBattery
    /// On battery with Low Power Mode on.
    case lowPowerMode

    /// The background task should wait for the charger.
    nonisolated var requiresExternalPower: Bool {
        switch self {
        case .thermal: return false
        case .lowBattery, .lowPowerMode: return true
        }
    }

    /// Short reason for the transcript screen / log.
    nonisolated var label: String {
        switch self {
        case .thermal: return "Waiting for the device to cool down"
        case .lowBattery: return "Waiting for the charger or more battery"
        case .lowPowerMode: return "Waiting for the charger (Low Power Mode is on)"
        }
    }
}

enum MobileDiarizationDecision: Equatable, Sendable {
    case runNow
    case deferred(MobileDiarizationDeferral)
}

enum MobileDiarizationPolicy {

    /// On battery, diarization runs right away only above this level.
    nonisolated static let minimumBatteryLevel = 0.30

    /// How long a thermally deferred job waits before iOS may try again.
    nonisolated static let thermalRetryDelay: TimeInterval = 15 * 60

    /// Run now when charging or the battery is above 30 % (and Low Power
    /// Mode is off), and the device isn't thermally serious. An unknown
    /// battery level (Simulator) counts as healthy.
    nonisolated static func decide(_ conditions: MobileDiarizationConditions) -> MobileDiarizationDecision {
        switch conditions.thermalState {
        case .serious, .critical:
            return .deferred(.thermal)
        case .nominal, .fair:
            break
        @unknown default:
            break
        }
        if conditions.isOnExternalPower { return .runNow }
        if conditions.isLowPowerMode { return .deferred(.lowPowerMode) }
        if let level = conditions.batteryLevel, level <= minimumBatteryLevel {
            return .deferred(.lowBattery)
        }
        return .runNow
    }

    /// Maps `UIDevice.batteryLevel` (-1 when unknown) onto 0…1 or nil.
    nonisolated static func batteryLevel(fromDeviceLevel raw: Float) -> Double? {
        guard raw.isFinite, raw >= 0 else { return nil }
        return min(Double(raw), 1)
    }

    /// When a deferred job should be retried by the background task.
    nonisolated static func earliestRetry(for deferral: MobileDiarizationDeferral, now: Date) -> Date? {
        deferral == .thermal ? now.addingTimeInterval(thermalRetryDelay) : nil
    }
}
