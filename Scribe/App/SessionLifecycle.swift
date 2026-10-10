import Combine
import Foundation

// MARK: - Start gate

/// Pure bookkeeping for "a recording is starting".
///
/// `AppState.isTranscribing` only flips once permissions are checked, the
/// speech model is installed and audio capture is running, which can take
/// seconds (or minutes, on a first model download). Without a separate
/// "starting" state two starts (auto-record plus a click) both pass the
/// `isTranscribing` guard and race. The gate is claimed before the first
/// await of a start and released when the start finishes either way.
///
/// A stop that arrives while a start is still in flight is absorbed here: the
/// start notices `stopRequested` at its next checkpoint and rolls back.
struct SessionStartGate: Equatable, Sendable {

    /// True from the moment a start is claimed until it ends.
    private(set) var isStarting = false

    /// Set when someone asked to stop while the start was in flight.
    private(set) var stopRequested = false

    /// Claims the gate. Returns false (and changes nothing) when a start is
    /// already in flight or a session is already running.
    mutating func begin(isRunning: Bool) -> Bool {
        guard !isStarting, !isRunning else { return false }
        isStarting = true
        stopRequested = false
        return true
    }

    /// Records a stop request. Returns true when a start is in flight and will
    /// cancel itself; false when there is nothing starting (the caller should
    /// stop a running session normally).
    mutating func requestStop() -> Bool {
        guard isStarting else { return false }
        stopRequested = true
        return true
    }

    /// Releases the gate after the start succeeded, failed or was cancelled.
    mutating func end() {
        isStarting = false
        stopRequested = false
    }
}

// MARK: - Keep-awake assertion

/// Keeps the Mac from idle-sleeping while a recording (and the work that
/// finishes it: summary, diarization) is running.
///
/// Wraps `ProcessInfo.beginActivity`. `end()` is idempotent, so the stop path
/// and a safety timeout can both call it.
@MainActor
final class SystemActivityAssertion {

    private var token: NSObjectProtocol?

    /// Options used for recordings: user-initiated work that must not be
    /// interrupted by idle system sleep. The display may still sleep.
    nonisolated static let recordingOptions: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]

    init(reason: String, options: ProcessInfo.ActivityOptions = SystemActivityAssertion.recordingOptions) {
        token = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    var isActive: Bool { token != nil }

    /// Ends the activity. Safe to call more than once.
    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

// MARK: - Heavy post-processing conditions

/// Decides whether heavy post-meeting work (speaker diarization) should run
/// now or wait until the Mac is cooler / off Low Power Mode.
enum HeavyWorkConditions {

    /// True when heavy work should be deferred: the system is thermally
    /// stressed (`.serious` / `.critical`) or Low Power Mode is on.
    nonisolated static func shouldDefer(thermalState: ProcessInfo.ThermalState, isLowPowerMode: Bool) -> Bool {
        if isLowPowerMode { return true }
        switch thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return false
        }
    }

    /// The current system conditions.
    nonisolated static func shouldDeferNow() -> Bool {
        let info = ProcessInfo.processInfo
        return shouldDefer(thermalState: info.thermalState, isLowPowerMode: info.isLowPowerModeEnabled)
    }

    /// Human-readable reason for the log line.
    nonisolated static func describeCurrent() -> String {
        let info = ProcessInfo.processInfo
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return "thermal state \(thermal), Low Power Mode \(info.isLowPowerModeEnabled ? "on" : "off")"
    }
}

// MARK: - Preference change filtering

extension Publisher where Output: Equatable {

    /// Emits only values that differ from `initial` and from the previous
    /// emission. `UserDefaults.didChangeNotification` fires for *every*
    /// defaults write, so a plain `removeDuplicates()` would still let the
    /// first (unchanged) value through on the first unrelated settings change.
    func changes(from initial: Output) -> AnyPublisher<Output, Failure> {
        prepend(initial)
            .removeDuplicates()
            .dropFirst()
            .eraseToAnyPublisher()
    }
}
