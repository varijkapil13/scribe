import AppKit
import Foundation
import UserNotifications

/// Watches for meeting apps (Zoom, Teams, Meet in a browser…) taking the
/// microphone and reacts per the user's settings: offer to record (a
/// notification with a "Start Recording" action) or start recording outright,
/// and — once the call releases the mic — offer to stop or stop automatically.
///
/// Detection is event-driven: CoreAudio property listeners
/// (`MicrophoneUsageObserver`) on the process list and each process's "is
/// running input" flag trigger a (debounced) sample of who holds the mic
/// (`MicrophoneUsageMonitor`), which the pure `MeetingDetectionPolicy` turns
/// into started/ended events. Follow-up samples are scheduled only for the
/// policy's own deadlines (start delay, end grace), plus a slow safety-net
/// poll — slower still in Low Power Mode. Nothing is recorded or stored by
/// detection itself; it only looks at *which app* holds the mic, never at
/// audio.
@MainActor
final class MeetingDetector: ObservableObject {

    static let shared = MeetingDetector()

    // MARK: - Settings keys

    static let includeBrowsersKey = "meetingDetectionIncludeBrowsers"
    static let includeOtherAppsKey = "meetingDetectionIncludeOtherApps"

    // MARK: - Notification identifiers

    nonisolated static let startCategoryId = "scribe.meeting-detected"
    nonisolated static let endCategoryId = "scribe.meeting-ended"
    nonisolated static let actionStart = "scribe.meeting.start"
    nonisolated static let actionStop = "scribe.meeting.stop"
    nonisolated static let userInfoAppName = "appName"
    nonisolated static let userInfoAppKind = "appKind"
    private static let startRequestId = "scribe.meeting.prompt"
    private static let endRequestId = "scribe.meeting.ended"

    static var notificationCategories: Set<UNNotificationCategory> {
        let start = UNNotificationCategory(
            identifier: startCategoryId,
            actions: [UNNotificationAction(identifier: actionStart, title: "Start Recording", options: [])],
            intentIdentifiers: [],
            options: []
        )
        let end = UNNotificationCategory(
            identifier: endCategoryId,
            actions: [UNNotificationAction(identifier: actionStop, title: "Stop Recording", options: [])],
            intentIdentifiers: [],
            options: []
        )
        return [start, end]
    }

    // MARK: - State

    /// The meeting currently detected, for UI (nil when none / detection off).
    @Published private(set) var currentMeeting: MeetingApp?

    private var policy = MeetingDetectionPolicy()
    private var ownership = MeetingRecordingOwnership()
    private var defaultsObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    /// Starts a recording; returns the id of the session it started (nil
    /// when the start was refused, cancelled or failed).
    private var startRecording: (@MainActor (MeetingApp, _ forceNewNote: Bool) async -> String?)?
    private var stopRecording: (@MainActor () async -> Void)?
    private var isRecording: @MainActor () -> Bool = { false }
    private var currentSessionId: @MainActor () -> String? = { nil }

    /// Whether detection is running (mode is not `.off`).
    private var isActive = false
    /// CoreAudio change notifications (process list + per-process input).
    private var usageObserver: MicrophoneUsageObserver?
    /// Safety-net poll; slow, with tolerance so wake-ups coalesce.
    private var fallbackTimer: Timer?
    /// Pending debounced sample after a CoreAudio notification.
    private var debounceTask: Task<Void, Never>?
    /// Pending sample at the policy's next deadline (start delay / end grace).
    private var deadlineTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Wires the detector to the app's recording actions and starts watching
    /// if the user has detection on. Re-evaluates whenever settings change.
    ///
    /// - Parameter currentSessionId: The running recording's session id, so
    ///   detection can tell a recording it started from one started by hand.
    func start(
        isRecording: @escaping @MainActor () -> Bool,
        currentSessionId: @escaping @MainActor () -> String? = { nil },
        startRecording: @escaping @MainActor (MeetingApp, _ forceNewNote: Bool) async -> String?,
        stopRecording: @escaping @MainActor () async -> Void
    ) {
        self.isRecording = isRecording
        self.currentSessionId = currentSessionId
        self.startRecording = startRecording
        self.stopRecording = stopRecording

        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyMode() }
            }
        }
        applyMode()
    }

    static var mode: MeetingDetectionMode {
        UserDefaults.standard.string(forKey: MeetingDetectionMode.defaultsKey)
            .flatMap(MeetingDetectionMode.init(rawValue:)) ?? MeetingDetectionMode.defaultValue
    }

    static var endAction: MeetingEndAction {
        UserDefaults.standard.string(forKey: MeetingEndAction.defaultsKey)
            .flatMap(MeetingEndAction.init(rawValue:)) ?? MeetingEndAction.defaultValue
    }

    /// Starts or stops watching to match the current mode.
    private func applyMode() {
        if Self.mode == .off {
            guard isActive else { return }
            isActive = false
            usageObserver?.stop()
            usageObserver = nil
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            debounceTask?.cancel()
            debounceTask = nil
            deadlineTask?.cancel()
            deadlineTask = nil
            if let powerObserver {
                NotificationCenter.default.removeObserver(powerObserver)
                self.powerObserver = nil
            }
            policy.reset()
            ownership.clear()
            currentMeeting = nil
            removeNotifications([Self.startRequestId, Self.endRequestId])
            Log.audio.info("Meeting detection off.")
        } else if !isActive {
            isActive = true
            Log.audio.info("Meeting detection on (\(Self.mode.rawValue, privacy: .public)).")

            let observer = MicrophoneUsageObserver()
            observer.onChange = { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleDebouncedTick() }
            }
            if !observer.start() {
                Log.audio.info("Mic-usage listeners unavailable; meeting detection falls back to polling.")
            }
            usageObserver = observer

            if powerObserver == nil {
                powerObserver = NotificationCenter.default.addObserver(
                    forName: Self.powerStateDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rescheduleFallbackTimer() }
                }
            }
            rescheduleFallbackTimer()
            tick()
        }
    }

    // MARK: - Scheduling

    /// Posted when Low Power Mode is switched on or off. Isolated here: the
    /// Swift spelling of `NSProcessInfoPowerStateDidChangeNotification`.
    private static var powerStateDidChange: Notification.Name {
        .NSProcessInfoPowerStateDidChange
    }

    /// (Re)creates the safety-net poll for the current power state.
    private func rescheduleFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        guard isActive else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let interval = MeetingDetectionSchedule.fallbackInterval(
            lowPowerMode: lowPower,
            listenersActive: usageObserver?.isObserving ?? false
        )
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = MeetingDetectionSchedule.tolerance(for: interval)
        fallbackTimer = timer
        Log.audio.debug("Meeting detection fallback poll every \(Int(interval)) s (Low Power Mode \(lowPower ? "on" : "off", privacy: .public)).")
    }

    /// Samples shortly after a burst of CoreAudio notifications settles.
    private func scheduleDebouncedTick() {
        guard isActive else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: MeetingDetectionSchedule.debounce)
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    /// Samples again when the policy's next deadline passes (a candidate
    /// meeting reaching its start delay, or an idle meeting's end grace).
    private func scheduleDeadlineTick() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard isActive, let deadline = policy.nextEvaluation() else { return }
        // A little slack so the sample lands just after the deadline.
        let wait = max(0, deadline.timeIntervalSinceNow) + 0.25
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    // MARK: - Sampling

    private func tick() {
        guard isActive else { return }
        defer { scheduleDeadlineTick() }
        // The recording detection started has stopped (by any means): forget it.
        if !ownership.ownsRecording(currentSessionId: currentSessionId()) {
            ownership.clear()
        }
        let defaults = UserDefaults.standard
        let includeBrowsers = defaults.object(forKey: Self.includeBrowsersKey) as? Bool ?? true
        let includeOthers = defaults.bool(forKey: Self.includeOtherAppsKey)
        let useCamera = defaults.object(forKey: MeetingSignals.useCameraKey) as? Bool ?? true

        let samples = MicrophoneUsageMonitor.activeInputProcesses().map { process in
            MeetingProcessSample(
                bundleID: process.bundleID,
                name: NSRunningApplication(processIdentifier: process.pid)?.localizedName
            )
        }
        // Remember non-catalog mic users so Settings can offer them.
        MeetingAppHistory.record(samples, in: defaults)
        // Only ask CoreMediaIO when something holds the mic.
        let cameraInUse = useCamera && !samples.isEmpty && CameraUsageMonitor.isAnyCameraInUse()
        let active = MeetingSignals.activeMeetingApps(
            processes: samples,
            includeBrowsers: includeBrowsers,
            includeOtherApps: includeOthers,
            rules: MeetingAppRules.load(from: defaults),
            cameraInUse: cameraInUse,
            currentMeeting: policy.current
        )

        guard let event = policy.update(active: active, now: Date(), cameraInUse: cameraInUse) else { return }
        switch event {
        case .started(let app):
            currentMeeting = app
            meetingStarted(app)
        case .ended(let app):
            currentMeeting = nil
            meetingEnded(app)
        }
    }

    private func meetingStarted(_ app: MeetingApp) {
        Log.audio.info("Meeting detected: \(app.name, privacy: .public) (\(app.bundleID, privacy: .public)).")
        removeNotifications([Self.endRequestId])
        // Already recording (started by hand before the call): nothing to offer.
        guard !isRecording() else { return }

        switch Self.mode {
        case .off:
            return
        case .notify:
            // "Scribe Focus" filter: no "start transcribing?" prompts while it
            // asks. Notices about a recording that is actually running
            // (auto-started / still recording / stopped) are kept.
            guard !ScribeFocusPreferences.isMutingMeetingPrompts() else {
                Log.audio.info("Meeting prompt muted by the Scribe Focus filter.")
                return
            }
            post(
                id: Self.startRequestId,
                category: Self.startCategoryId,
                // Name the meeting after the calendar event in progress, if
                // calendar integration is on and one matches.
                title: "\(CalendarService.shared.matchingEvent()?.displayTitle ?? Self.meetingPhrase(for: app)) detected",
                body: "\(app.name) is using your microphone. Start transcribing?",
                app: app
            )
        case .autoRecord:
            Task {
                // Only the session this very call started is detection's own
                // (a manual start racing this one is refused here, or wins and
                // makes this one refused — either way it is never claimed).
                let sessionId = await startRecording?(app, true)
                // Only announce what actually happened (start can fail on a
                // missing permission). The banner carries a Stop action.
                guard let sessionId, isRecording(), currentSessionId() == sessionId else { return }
                // This recording is detection's own: it may stop it again
                // when the meeting ends.
                ownership.detectorStarted(sessionId: sessionId)
                post(
                    id: Self.startRequestId,
                    category: Self.endCategoryId,
                    title: "Recording \(Self.meetingPhrase(for: app).lowercased())",
                    body: "Scribe started transcribing because \(app.name) is using your microphone.",
                    app: app
                )
            }
        }
    }

    private func meetingEnded(_ app: MeetingApp) {
        Log.audio.info("Meeting ended: \(app.name, privacy: .public).")
        removeNotifications([Self.startRequestId])
        let response = ownership.endResponse(
            endAction: Self.endAction,
            isRecording: isRecording(),
            currentSessionId: currentSessionId()
        )
        ownership.clear()

        switch response {
        case .ignore:
            return
        case .ask:
            post(
                id: Self.endRequestId,
                category: Self.endCategoryId,
                title: "\(Self.meetingPhrase(for: app)) ended?",
                body: "\(app.name) released the microphone. Scribe is still recording.",
                app: app
            )
        case .stop:
            Task {
                await stopRecording?()
                post(
                    id: Self.endRequestId,
                    category: "",
                    title: "Recording stopped",
                    body: "\(app.name) released the microphone, so Scribe stopped transcribing.",
                    app: app
                )
            }
        }
    }

    // MARK: - Notification responses

    /// Routed from the shared `UNUserNotificationCenter` delegate
    /// (`TaskReminderScheduler.externalResponseHandler`).
    func handleNotificationResponse(categoryId: String, actionId: String, userInfo: [String: String]) {
        switch (categoryId, actionId) {
        case (Self.startCategoryId, Self.actionStart),
             (Self.startCategoryId, UNNotificationDefaultActionIdentifier):
            guard !isRecording() else { return }
            let app = currentMeeting ?? MeetingApp(
                bundleID: "",
                name: userInfo[Self.userInfoAppName] ?? "Meeting",
                kind: userInfo[Self.userInfoAppKind].flatMap(MeetingApp.Kind.init(rawValue:)) ?? .other
            )
            // A person chose to record: follow the normal Record rules (bind to
            // the open note if there is one), unlike auto-record.
            Task { _ = await startRecording?(app, false) }
        case (Self.endCategoryId, Self.actionStop):
            guard isRecording() else { return }
            Task { await stopRecording?() }
        default:
            break
        }
    }

    // MARK: - Helpers

    /// "Zoom meeting" / "Meeting" — browsers and unknown apps don't name the
    /// meeting ("Google Chrome meeting" reads wrong).
    nonisolated static func meetingPhrase(for app: MeetingApp) -> String {
        app.kind == .conferencing ? "\(app.name) meeting" : "Meeting"
    }

    private func post(id: String, category: String, title: String, body: String, app: MeetingApp) {
        Task {
            // Lazy authorization, shared with task reminders: the first
            // detected meeting is the moment the prompt makes sense.
            guard await TaskReminderScheduler.shared.ensureAuthorized() else {
                Log.audio.info("Meeting notification skipped — notifications not authorized.")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = [Self.userInfoAppName: app.name, Self.userInfoAppKind: app.kind.rawValue]
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.audio.error("Failed to post meeting notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func removeNotifications(_ ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
