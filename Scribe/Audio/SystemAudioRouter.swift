import AVFoundation
import CoreGraphics
import Foundation

// MARK: - SystemAudioRouter

/// The ``SystemAudioSource`` the session talks to: picks the Core Audio
/// process tap or ScreenCaptureKit per ``SystemAudioSourcePolicy``, falls
/// back to the other one when the first fails (to start, or mid-session),
/// and probes the System Audio Recording permission while the tap runs.
///
/// Contract as for every ``SystemAudioSource``; in addition
/// ``onCaptureWillRestart`` fires just before capture comes back after a
/// gap (a tap rebuild or a switch of backend), so the session can measure
/// that gap precisely.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`. Mid-session
/// switches run in one `Task` at a time (`_switchTask`), which
/// ``stopCapture()`` and ``startCapture(sampleRate:)`` wait for; a
/// generation counter makes a switch that lost a race with a stop undo
/// itself.
final class SystemAudioRouter: SystemAudioSource, @unchecked Sendable {

    let processTap = ProcessTapCapture()
    let screenCapture = SystemAudioCapture()

    private let lock = NSLock()
    private var _active: SystemAudioBackendKind?
    private var _plan: [SystemAudioBackendKind] = []
    private var _sampleRate: Double = 16000
    /// The meeting app the current session's tap narrows to (nil = global).
    private var _sessionMeetingBundleID: String?
    /// Bumped by every start and stop; a switch only commits while it holds.
    private var _generation = 0
    private var _switchTask: Task<Void, Never>?
    private var _probeTask: Task<Void, Never>?
    private var _meetingBundleID: String?
    private var _onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var _onStreamError: ((Error) -> Void)?
    private var _onCaptureWillRestart: (() -> Void)?

    init() {
        processTap.onStreamError = { [weak self] error in
            self?.backendFailed(.processTap, error: error)
        }
        screenCapture.onStreamError = { [weak self] error in
            self?.backendFailed(.screenCaptureKit, error: error)
        }
        processTap.onCaptureWillRestart = { [weak self] in
            self?.onCaptureWillRestart?()
        }
    }

    // MARK: Callbacks

    /// Forwarded to both backends, so whichever runs delivers through it.
    var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { lock.withLock { _onAudioBuffer } }
        set {
            lock.withLock { _onAudioBuffer = newValue }
            processTap.onAudioBuffer = newValue
            screenCapture.onAudioBuffer = newValue
        }
    }

    /// Called when system audio stopped and no fallback could take over.
    var onStreamError: ((Error) -> Void)? {
        get { lock.withLock { _onStreamError } }
        set { lock.withLock { _onStreamError = newValue } }
    }

    /// Called (on an arbitrary queue) just before capture resumes after a
    /// tap rebuild or a backend switch.
    var onCaptureWillRestart: (() -> Void)? {
        get { lock.withLock { _onCaptureWillRestart } }
        set { lock.withLock { _onCaptureWillRestart = newValue } }
    }

    /// Canonical bundle ID of the detected meeting app, if any. Used at the
    /// next start when "Tap only the meeting app" is on.
    var meetingBundleID: String? {
        get { lock.withLock { _meetingBundleID } }
        set { lock.withLock { _meetingBundleID = newValue } }
    }

    /// The backend currently capturing (or being switched to), if any.
    var activeBackend: SystemAudioBackendKind? {
        lock.withLock { _active }
    }

    var isCapturing: Bool {
        switch activeBackend {
        case .processTap?:       return processTap.isCapturing
        case .screenCaptureKit?: return screenCapture.isCapturing
        case nil:                return false
        }
    }

    // MARK: Plan

    /// The backends to try right now, from the settings and permissions.
    nonisolated static func currentPlan() -> [SystemAudioBackendKind] {
        let defaults = UserDefaults.standard
        return SystemAudioSourcePolicy.plan(
            preference: SystemAudioSourcePreference.current(in: defaults),
            tapPermission: ProcessTapPermissionState.load(from: defaults),
            tapSupported: ProcessTapCapture.isSupported,
            screenCapturePermitted: CGPreflightScreenCaptureAccess()
        )
    }

    /// Whether system audio can only work with Screen Recording granted
    /// (so the start flow should ask for it up front).
    nonisolated static func requiresScreenRecording() -> Bool {
        let defaults = UserDefaults.standard
        return SystemAudioSourcePolicy.requiresScreenRecording(
            preference: SystemAudioSourcePreference.current(in: defaults),
            tapPermission: ProcessTapPermissionState.load(from: defaults),
            tapSupported: ProcessTapCapture.isSupported
        )
    }

    // MARK: SystemAudioSource

    /// True when some backend can be tried (see ``SystemAudioSourcePolicy``).
    func checkPermission() async -> Bool {
        !Self.currentPlan().isEmpty
    }

    func startCapture(sampleRate: Double = 16000) async throws {
        await waitForSwitch()
        guard !isCapturing else { return }

        let plan = Self.currentPlan()
        let meetingAppOnly = UserDefaults.standard.bool(forKey: SystemAudioTapSettings.meetingAppOnlyKey)
        let meeting = meetingAppOnly ? meetingBundleID : nil
        let generation = lock.withLock { () -> Int in
            _generation += 1
            _plan = plan
            _sampleRate = sampleRate
            _sessionMeetingBundleID = meeting
            _active = nil
            return _generation
        }
        guard !plan.isEmpty else { throw SystemAudioCaptureError.permissionDenied }

        var lastError: Error = SystemAudioCaptureError.streamCreationFailed
        for kind in plan {
            lock.withLock { _active = kind }
            do {
                try await start(kind, sampleRate: sampleRate, meetingBundleID: meeting)
                Log.audio.info("System audio is captured with \(kind.rawValue, privacy: .public).")
                if kind == .processTap {
                    startPermissionProbe(generation: generation, meetingBundleID: meeting)
                }
                return
            } catch {
                Log.audio.error("System audio via \(kind.rawValue, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        lock.withLock { _active = nil }
        throw lastError
    }

    func stopCapture() async {
        let (switchTask, probeTask) = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            _generation += 1
            let tasks = (_switchTask, _probeTask)
            _switchTask = nil
            _probeTask = nil
            return tasks
        }
        probeTask?.cancel()
        await switchTask?.value
        lock.withLock { _active = nil }
        // Both are idempotent; stopping both also covers a switch caught
        // half-way.
        await processTap.stopCapture()
        await screenCapture.stopCapture()
    }

    // MARK: Backends

    private func start(_ kind: SystemAudioBackendKind, sampleRate: Double, meetingBundleID: String?) async throws {
        switch kind {
        case .processTap:
            try await processTap.startCapture(sampleRate: sampleRate, meetingBundleID: meetingBundleID)
        case .screenCaptureKit:
            try await screenCapture.startCapture(sampleRate: sampleRate)
        }
    }

    private func stop(_ kind: SystemAudioBackendKind) async {
        switch kind {
        case .processTap:       await processTap.stopCapture()
        case .screenCaptureKit: await screenCapture.stopCapture()
        }
    }

    private func waitForSwitch() async {
        let task = lock.withLock { _switchTask }
        await task?.value
    }

    // MARK: Fallback

    /// A backend stopped unexpectedly: switch to the next one in the plan,
    /// or report the error when there is none.
    private func backendFailed(_ kind: SystemAudioBackendKind, error: Error) {
        let isActive = lock.withLock { _active == kind }
        guard isActive else { return } // stale: we already moved on
        if !scheduleSwitch(from: kind) {
            lock.withLock {
                if _active == kind { _active = nil }
            }
            onStreamError?(error)
        }
    }

    /// Starts switching away from `old` to its fallback in the plan.
    /// Returns false when there is no fallback (or `old` isn't current).
    @discardableResult
    private func scheduleSwitch(from old: SystemAudioBackendKind) -> Bool {
        lock.withLock { () -> Bool in
            guard _active == old, _switchTask == nil,
                  let next = SystemAudioSourcePolicy.fallback(after: old, in: _plan) else { return false }
            let generation = _generation
            let sampleRate = _sampleRate
            let meeting = _sessionMeetingBundleID
            _switchTask = Task { [weak self] in
                await self?.performSwitch(
                    from: old, to: next, generation: generation,
                    sampleRate: sampleRate, meetingBundleID: meeting
                )
            }
            return true
        }
    }

    private func performSwitch(
        from old: SystemAudioBackendKind,
        to next: SystemAudioBackendKind,
        generation: Int,
        sampleRate: Double,
        meetingBundleID: String?
    ) async {
        Log.audio.info("Switching system audio from \(old.rawValue, privacy: .public) to \(next.rawValue, privacy: .public).")
        await stop(old)
        let stillCurrent = lock.withLock { () -> Bool in
            guard _generation == generation else { return false }
            _active = next
            return true
        }
        guard stillCurrent else { return }

        onCaptureWillRestart?()
        do {
            try await start(next, sampleRate: sampleRate, meetingBundleID: meetingBundleID)
            let committed = lock.withLock { () -> Bool in
                guard _generation == generation else { return false }
                _switchTask = nil
                return true
            }
            if !committed {
                // A stop came in while starting; it may have missed this one.
                await stop(next)
            } else if next == .processTap {
                startPermissionProbe(generation: generation, meetingBundleID: meetingBundleID)
            }
        } catch {
            Log.audio.error("System audio fallback to \(next.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            let current = lock.withLock { () -> Bool in
                guard _generation == generation else { return false }
                _active = nil
                _switchTask = nil
                return true
            }
            if current { onStreamError?(error) }
        }
    }

    // MARK: Permission probe

    /// While the tap runs and the grant isn't known yet, watches what it
    /// delivers (``ProcessTapPermissionProbe``); a suspected denial is
    /// remembered and moves capture to ScreenCaptureKit when the plan allows.
    private func startPermissionProbe(generation: Int, meetingBundleID: String?) {
        guard ProcessTapPermissionState.load(from: UserDefaults.standard) != .granted else { return }
        let task = Task { [weak self] in
            var probe = ProcessTapPermissionProbe()
            let interval = ProcessTapPermissionProbe.checkIntervalSeconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.isProbing(generation: generation) else { return }
                let verdict = probe.observe(
                    intervalSeconds: interval,
                    sawSignal: self.processTap.hasObservedSignal,
                    othersPlaying: ProcessTapCoreAudio.isTappedAudioPlaying(meetingBundleID: meetingBundleID)
                )
                switch verdict {
                case .undecided:
                    continue
                case .granted:
                    ProcessTapPermissionState.granted.store(in: UserDefaults.standard)
                    return
                case .suspectedDenied:
                    Log.audio.error("System audio tap hears only silence while other apps play audio — System Audio Recording looks denied.")
                    ProcessTapPermissionState.suspectedDenied.store(in: UserDefaults.standard)
                    if !self.scheduleSwitch(from: .processTap) {
                        // No fallback (Screen Recording not granted): keep
                        // the tap running in case this is a false alarm, but
                        // tell the user instead of recording silence quietly.
                        self.onStreamError?(ProcessTapCaptureError.permissionLikelyDenied)
                    }
                    return
                case .inconclusive:
                    return
                }
            }
        }
        lock.withLock { _probeTask = task }
    }

    private func isProbing(generation: Int) -> Bool {
        lock.withLock { _generation == generation && _active == .processTap }
    }
}
