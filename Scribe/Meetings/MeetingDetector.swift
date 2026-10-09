import AppKit
import Foundation
import UserNotifications

/// Watches for meeting apps (Zoom, Teams, Meet in a browser…) taking the
/// microphone and reacts per the user's settings: offer to record (a
/// notification with a "Start Recording" action) or start recording outright,
/// and — once the call releases the mic — offer to stop or stop automatically.
///
/// Detection is a cheap 2-second poll of CoreAudio's per-process "is running
/// input" flag (`MicrophoneUsageMonitor`), debounced by the pure
/// `MeetingDetectionPolicy`. Polling (rather than property listeners) keeps
/// this robust to processes coming and going, and costs a handful of property
/// reads per tick. Nothing is recorded or stored by detection itself; it only
/// looks at *which app* holds the mic, never at audio.
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
    private var pollTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var startRecording: (@MainActor (MeetingApp, _ forceNewNote: Bool) async -> Void)?
    private var stopRecording: (@MainActor () async -> Void)?
    private var isRecording: @MainActor () -> Bool = { false }

    private static let pollInterval: Duration = .seconds(2)

    // MARK: - Lifecycle

    /// Wires the detector to the app's recording actions and starts polling if
    /// the user has detection on. Re-evaluates whenever settings change.
    func start(
        isRecording: @escaping @MainActor () -> Bool,
        startRecording: @escaping @MainActor (MeetingApp, _ forceNewNote: Bool) async -> Void,
        stopRecording: @escaping @MainActor () async -> Void
    ) {
        self.isRecording = isRecording
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

    /// Starts or stops the poll loop to match the current mode.
    private func applyMode() {
        if Self.mode == .off {
            guard pollTask != nil else { return }
            pollTask?.cancel()
            pollTask = nil
            policy.reset()
            currentMeeting = nil
            removeNotifications([Self.startRequestId, Self.endRequestId])
            Log.audio.info("Meeting detection off.")
        } else if pollTask == nil {
            Log.audio.info("Meeting detection on (\(Self.mode.rawValue, privacy: .public)).")
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
        }
    }

    // MARK: - Polling

    private func tick() {
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
                await startRecording?(app, true)
                // Only announce what actually happened (start can fail on a
                // missing permission). The banner carries a Stop action.
                guard isRecording() else { return }
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
        guard isRecording() else { return }

        switch Self.endAction {
        case .nothing:
            return
        case .notify:
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
            Task { await startRecording?(app, false) }
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
