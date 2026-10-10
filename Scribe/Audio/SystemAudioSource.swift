import AVFoundation
import Foundation

// MARK: - SystemAudioSource

/// Something that captures other apps' audio (the remote side of a meeting)
/// and hands it to the session as 16 kHz mono Float32 buffers.
///
/// Two implementations exist: ``ProcessTapCapture`` (Core Audio process taps,
/// the primary path) and ``SystemAudioCapture`` (ScreenCaptureKit, the
/// fallback). ``SystemAudioRouter`` picks between them and is what
/// ``AudioSessionManager`` talks to.
///
/// Contract shared by every source:
/// - ``onAudioBuffer`` is called in capture order on one private serial
///   queue, with the buffer's start time on the host clock.
/// - ``onStreamError`` is called (on an arbitrary queue) when capture stops
///   unexpectedly mid-session.
/// - ``startCapture(sampleRate:)`` / ``stopCapture()`` are not meant to
///   overlap; the caller runs them one at a time.
protocol SystemAudioSource: AnyObject, Sendable {
    /// Whether capture is currently running.
    var isCapturing: Bool { get }
    /// Receives each captured buffer with its host-clock start time.
    var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }
    /// Receives an unexpected mid-session failure.
    var onStreamError: ((Error) -> Void)? { get set }
    /// Whether starting capture can be expected to work, without prompting.
    func checkPermission() async -> Bool
    /// Starts capture, delivering buffers at `sampleRate` (mono Float32).
    func startCapture(sampleRate: Double) async throws
    /// Stops capture. Idempotent.
    func stopCapture() async
}

extension SystemAudioCapture: SystemAudioSource {}

// MARK: - Settings

/// Settings → General → Audio → "System audio source".
enum SystemAudioSourcePreference: String, CaseIterable, Identifiable, Sendable {
    /// Core Audio process tap first; ScreenCaptureKit when the tap can't be
    /// used (failed to start, or System Audio Recording looks denied).
    case automatic
    /// Always ScreenCaptureKit (needs Screen Recording permission).
    case screenCaptureKit

    nonisolated static let defaultsKey = "systemAudioSource"
    nonisolated static let defaultValue: SystemAudioSourcePreference = .automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:        return "Automatic (Core Audio tap)"
        case .screenCaptureKit: return "ScreenCaptureKit"
        }
    }

    /// The stored preference, or the default when unset / unrecognised.
    nonisolated static func current(in defaults: UserDefaults) -> SystemAudioSourcePreference {
        defaults.string(forKey: defaultsKey).flatMap(SystemAudioSourcePreference.init(rawValue:)) ?? defaultValue
    }
}

/// Other process-tap settings.
enum SystemAudioTapSettings {
    /// When on and a meeting app was detected, tap only that app's audio
    /// instead of everything except Scribe. Default off.
    nonisolated static let meetingAppOnlyKey = "systemAudioTapMeetingAppOnly"
}

/// What Scribe has learned about the System Audio Recording permission.
///
/// macOS offers no public way to check this permission: a tap created without
/// it simply delivers silence. So Scribe infers it — real signal from a tap
/// proves the grant; long, exact silence while other apps are playing audio
/// suggests a denial (see ``ProcessTapPermissionProbe``). Persisted so a
/// denied user isn't probed (and loses the first seconds of remote audio)
/// every session; Settings offers to forget it.
enum ProcessTapPermissionState: String, CaseIterable, Sendable {
    case unknown
    case granted
    case suspectedDenied

    nonisolated static let defaultsKey = "systemAudioTapPermission"

    nonisolated static func load(from defaults: UserDefaults) -> ProcessTapPermissionState {
        defaults.string(forKey: defaultsKey).flatMap(ProcessTapPermissionState.init(rawValue:)) ?? .unknown
    }

    nonisolated func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

// MARK: - Policy

/// A concrete system-audio capture backend.
enum SystemAudioBackendKind: String, CaseIterable, Sendable {
    case processTap
    case screenCaptureKit
}

/// Pure decisions behind ``SystemAudioRouter``: which backends to try, in
/// what order, and which processes a tap should cover. No Core Audio, no
/// ScreenCaptureKit — unit-tested.
enum SystemAudioSourcePolicy {

    /// Backends to try, in order; the first that starts wins and the next one
    /// is the fallback if it later fails. Empty when nothing can work (the
    /// caller reports a permission error).
    ///
    /// - Parameters:
    ///   - preference: The user's "System audio source" setting.
    ///   - tapPermission: What's known about System Audio Recording.
    ///   - tapSupported: Whether process taps exist on this system.
    ///   - screenCapturePermitted: Whether Screen Recording is granted.
    nonisolated static func plan(
        preference: SystemAudioSourcePreference,
        tapPermission: ProcessTapPermissionState,
        tapSupported: Bool,
        screenCapturePermitted: Bool
    ) -> [SystemAudioBackendKind] {
        switch preference {
        case .screenCaptureKit:
            // An explicit choice: never silently swap in the tap.
            return screenCapturePermitted ? [.screenCaptureKit] : []
        case .automatic:
            guard tapSupported else {
                return screenCapturePermitted ? [.screenCaptureKit] : []
            }
            switch tapPermission {
            case .unknown, .granted:
                return screenCapturePermitted ? [.processTap, .screenCaptureKit] : [.processTap]
            case .suspectedDenied:
                // Prefer the path that works; still try the tap when it's the
                // only option (the user may have granted it since).
                return screenCapturePermitted ? [.screenCaptureKit, .processTap] : [.processTap]
            }
        }
    }

    /// Whether system audio needs Screen Recording to work at all — i.e. the
    /// plan is empty without it. The start flow asks for that grant up front
    /// only then (the tap path needs System Audio Recording instead, which
    /// macOS prompts for itself).
    nonisolated static func requiresScreenRecording(
        preference: SystemAudioSourcePreference,
        tapPermission: ProcessTapPermissionState,
        tapSupported: Bool
    ) -> Bool {
        plan(
            preference: preference,
            tapPermission: tapPermission,
            tapSupported: tapSupported,
            screenCapturePermitted: false
        ).isEmpty
    }

    /// The backend to switch to after `failed` stopped working, or `nil` when
    /// the plan has nothing after it.
    nonisolated static func fallback(
        after failed: SystemAudioBackendKind,
        in plan: [SystemAudioBackendKind]
    ) -> SystemAudioBackendKind? {
        guard let index = plan.firstIndex(of: failed) else { return nil }
        let next = plan.index(after: index)
        return next < plan.endIndex ? plan[next] : nil
    }

    /// Whether an audio process (its bundle ID as Core Audio reports it)
    /// belongs to the detected meeting app (its canonical bundle ID). Matches
    /// the app itself, its dotted-prefix helpers (`com.google.Chrome.helper`)
    /// and any process the meeting catalog names as the same app (Safari's
    /// audio runs in `com.apple.WebKit.GPU`, catalogued as "Safari" too).
    nonisolated static func processBelongsToMeetingApp(
        processBundleID: String,
        meetingBundleID: String
    ) -> Bool {
        guard !processBundleID.isEmpty, !meetingBundleID.isEmpty else { return false }
        if processBundleID == meetingBundleID || processBundleID.hasPrefix(meetingBundleID + ".") {
            return true
        }
        let rules = MeetingAppRules()
        guard let process = MeetingAppCatalog.match(
                  bundleID: processBundleID, includeBrowsers: true, includeOtherApps: false, rules: rules),
              let meeting = MeetingAppCatalog.match(
                  bundleID: meetingBundleID, includeBrowsers: true, includeOtherApps: false, rules: rules)
        else { return false }
        return process.bundleID == meeting.bundleID
            || (process.kind == meeting.kind && process.name == meeting.name)
    }

    /// Which processes a tap should cover.
    enum TapScope: Equatable, Sendable {
        /// Every process except the excluded ones (Scribe itself).
        case global
        /// Only the given meeting-app processes.
        case meetingApp
    }

    /// A per-app tap only when the user asked for it, a meeting app is known,
    /// and at least one of its audio processes exists right now; otherwise
    /// the global tap (which can't miss audio).
    nonisolated static func tapScope(
        meetingAppOnly: Bool,
        meetingBundleID: String?,
        matchingProcessCount: Int
    ) -> TapScope {
        guard meetingAppOnly,
              let meetingBundleID, !meetingBundleID.isEmpty,
              matchingProcessCount > 0 else { return .global }
        return .meetingApp
    }
}

// MARK: - Permission probe

/// Infers the System Audio Recording permission from what a running tap
/// delivers (see ``ProcessTapPermissionState`` for why it must be inferred).
///
/// Fed one observation every few seconds:
/// - any non-zero sample proves the grant;
/// - exact digital silence for ``suspicionThresholdSeconds`` (cumulative)
///   *while another process is playing audio* suggests a denial;
/// - after ``maxProbeSeconds`` without either, it gives up (inconclusive).
///
/// Generous threshold on purpose: a false "denied" only moves the user onto
/// the ScreenCaptureKit fallback (and Settings shows how to undo it), while a
/// missed denial would leave the remote side silent for the whole session.
struct ProcessTapPermissionProbe: Equatable, Sendable {

    enum Verdict: Equatable, Sendable {
        case undecided
        case granted
        case suspectedDenied
        case inconclusive
    }

    /// Seconds between observations the router makes.
    nonisolated static let checkIntervalSeconds: Double = 2

    let suspicionThresholdSeconds: Double
    let maxProbeSeconds: Double

    private(set) var elapsedSeconds: Double = 0
    private(set) var suspiciousSeconds: Double = 0

    init(suspicionThresholdSeconds: Double = 24, maxProbeSeconds: Double = 180) {
        self.suspicionThresholdSeconds = suspicionThresholdSeconds
        self.maxProbeSeconds = maxProbeSeconds
    }

    /// Records one observation window.
    ///
    /// - Parameters:
    ///   - intervalSeconds: Length of the window.
    ///   - sawSignal: Whether the tap has delivered any non-zero sample so far.
    ///   - othersPlaying: Whether another process was running audio output.
    mutating func observe(intervalSeconds: Double, sawSignal: Bool, othersPlaying: Bool) -> Verdict {
        let interval = max(0, intervalSeconds)
        elapsedSeconds += interval
        if sawSignal { return .granted }
        if othersPlaying {
            suspiciousSeconds += interval
            if suspiciousSeconds >= suspicionThresholdSeconds { return .suspectedDenied }
        }
        if elapsedSeconds >= maxProbeSeconds { return .inconclusive }
        return .undecided
    }
}
