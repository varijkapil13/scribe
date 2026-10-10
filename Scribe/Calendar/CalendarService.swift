import EventKit
import Foundation

/// Calendar integration (EventKit). Off by default: nothing touches EventKit —
/// and no permission prompt appears — until the user turns it on in
/// Settings → Calendar, which calls `enable()`.
///
/// Keeps `upcomingEvents` (next 24 h) fresh every 15 minutes and whenever the
/// calendar database changes, and hands them to `CalendarReminderScheduler`
/// for pre-meeting reminders. Recording uses `matchingEvent(at:)` to name the
/// note after the event in progress.
@MainActor
final class CalendarService: ObservableObject {

    static let shared = CalendarService()

    // MARK: - Settings keys

    /// Master switch. Default off.
    static let enabledKey = "calendarIntegrationEnabled"
    /// Pre-meeting reminder notifications. Default on (only effective while
    /// the master switch is on).
    static let remindersKey = "calendarRemindBeforeMeetings"
    /// Name auto-created meeting notes after the matching event and seed them
    /// with attendees / agenda / link. Default on (gated by the master switch).
    static let nameNotesKey = "calendarNameNotesAfterEvents"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var remindersEnabled: Bool {
        UserDefaults.standard.object(forKey: remindersKey) as? Bool ?? true
    }
    static var nameNotesEnabled: Bool {
        UserDefaults.standard.object(forKey: nameNotesKey) as? Bool ?? true
    }

    // MARK: - Access state

    enum AccessState: Equatable {
        case notDetermined
        case granted
        case denied
        case restricted
        case writeOnly

        var label: String {
            switch self {
            case .notDetermined: return "Not requested"
            case .granted:       return "Full access granted"
            case .denied:        return "Denied"
            case .restricted:    return "Restricted"
            case .writeOnly:     return "Add-only (needs full access)"
            }
        }
    }

    @Published private(set) var accessState: AccessState
    /// Timed and all-day events in the next 24 hours, soonest first. Empty
    /// while the feature is off or access isn't granted.
    @Published private(set) var upcomingEvents: [CalendarEventInfo] = []

    // MARK: - Private

    /// Lazy so merely observing the service (menu bar, settings) never
    /// instantiates EventKit while the feature is off.
    private lazy var store = CalendarStore()
    private var refreshTask: Task<Void, Never>?
    private var storeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppliedSettings: (enabled: Bool, reminders: Bool)?

    private static let refreshInterval: Duration = .seconds(15 * 60)
    private static let lookahead: TimeInterval = 24 * 60 * 60

    private init() {
        accessState = Self.currentAccessState()
    }

    // MARK: - Lifecycle

    /// Called once at launch. Starts refreshing if the user enabled the
    /// feature earlier; never requests access itself.
    func start() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            }
        }
        settingsChanged()
    }

    /// Turns the feature on: requests full calendar access if it hasn't been
    /// decided yet, then refreshes. Returns whether access is granted.
    @discardableResult
    func enable() async -> Bool {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        if Self.currentAccessState() == .notDetermined {
            let granted = await store.requestFullAccess()
            Log.app.info("Calendar access request finished (granted: \(granted, privacy: .public)).")
        }
        updateAccessState()
        lastAppliedSettings = nil
        settingsChanged()
        return accessState == .granted
    }

    /// Re-reads the authorization status (e.g. after the user returns from
    /// System Settings).
    func refreshAccessState() {
        let previous = accessState
        updateAccessState()
        if previous != accessState {
            lastAppliedSettings = nil
            settingsChanged()
        }
    }

    /// Whether events can be read right now.
    var isActive: Bool { Self.isEnabled && accessState == .granted }

    // MARK: - Queries

    /// The event a recording starting at `date` belongs to, or nil when the
    /// feature is off / not authorized / nothing matches.
    func matchingEvent(at date: Date = Date()) -> CalendarEventInfo? {
        updateAccessState()
        guard isActive else { return nil }
        let window = CalendarEventMatcher.defaultWindow
        // Wide enough to include long events already in progress. Task time
        // blocks Scribe wrote itself are never a meeting to name a note after.
        let mirrored = TaskCalendarMirrorService.shared.mirroredEventIdentifiers()
        let events = store.events(
            from: date.addingTimeInterval(-12 * 60 * 60),
            to: date.addingTimeInterval(window + 60)
        ).filter { !mirrored.contains($0.id) }
        return CalendarEventMatcher.bestMatch(in: events, at: date, window: window)
    }

    /// The upcoming event with this identifier (and, when given, start time).
    func upcomingEvent(id: String, start: Date? = nil) -> CalendarEventInfo? {
        upcomingEvents.first { event in
            guard event.id == id else { return false }
            guard let start else { return true }
            return abs(event.start.timeIntervalSince(start)) < 1
        }
    }

    /// Re-fetches the next 24 hours and reschedules reminders.
    func refresh() {
        updateAccessState()
        guard isActive else {
            upcomingEvents = []
            CalendarReminderScheduler.shared.reschedule(events: [])
            return
        }
        let now = Date()
        // Task time blocks Scribe wrote itself aren't meetings: no pre-meeting
        // reminder or "upcoming meeting" entry for them.
        let mirrored = TaskCalendarMirrorService.shared.mirroredEventIdentifiers()
        upcomingEvents = store.events(from: now, to: now.addingTimeInterval(Self.lookahead))
            .filter { !mirrored.contains($0.id) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        CalendarReminderScheduler.shared.reschedule(
            events: Self.remindersEnabled ? upcomingEvents : []
        )
    }

    // MARK: - Private

    private func settingsChanged() {
        let settings = (enabled: Self.isEnabled, reminders: Self.remindersEnabled)
        if let last = lastAppliedSettings,
           last.enabled == settings.enabled, last.reminders == settings.reminders {
            return
        }
        lastAppliedSettings = settings
        updateAccessState()

        if isActive {
            observeStore()
            startRefreshLoop()
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            if let storeObserver {
                NotificationCenter.default.removeObserver(storeObserver)
                self.storeObserver = nil
            }
        }
        refresh()
    }

    private func observeStore() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    private func updateAccessState() {
        let state = Self.currentAccessState()
        if state != accessState { accessState = state }
    }

    private static func currentAccessState() -> AccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess:    return .granted
        case .writeOnly:     return .writeOnly
        case .restricted:    return .restricted
        case .denied:        return .denied
        @unknown default:    return .denied
        }
    }
}
