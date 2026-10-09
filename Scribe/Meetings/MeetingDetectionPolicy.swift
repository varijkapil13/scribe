import Foundation

/// What Scribe does when it notices a meeting app has started using the mic.
enum MeetingDetectionMode: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Post a notification with a "Start Recording" action (default).
    case notify
    /// Start recording straight away into a new meeting note.
    case autoRecord

    static let defaultsKey = "meetingDetectionMode"
    static let defaultValue: MeetingDetectionMode = .notify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return "Off"
        case .notify:     return "Ask me"
        case .autoRecord: return "Start recording automatically"
        }
    }
}

/// What Scribe does with a running recording once the detected meeting ends.
enum MeetingEndAction: String, CaseIterable, Identifiable, Sendable {
    case nothing
    /// Post a notification with a "Stop Recording" action (default).
    case notify
    /// Stop the recording automatically.
    case stop

    static let defaultsKey = "meetingEndAction"
    static let defaultValue: MeetingEndAction = .notify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: return "Keep recording"
        case .notify:  return "Ask me"
        case .stop:    return "Stop recording automatically"
        }
    }
}

/// Pure state machine that turns a stream of "which meeting apps are using the
/// mic right now" samples into debounced *meeting started* / *meeting ended*
/// events.
///
/// - A meeting **starts** once some meeting app has held the mic continuously
///   for `startDelay` — this filters out blips like an app probing the mic or
///   a Slack huddle preview.
/// - It **ends** once no meeting app has held the mic for `endGrace` — long
///   enough to ride out a device switch (AirPods connecting) or an app
///   briefly reopening its audio unit, short enough that auto-stop feels
///   responsive.
/// - While a meeting is in progress, a *different* app taking over (moving
///   from a Zoom to a Teams call back-to-back) is the same episode: no new
///   prompt, which also means a dismissed prompt is never repeated mid-call.
///
/// No clocks, CoreAudio, or AppKit — `MeetingDetector` feeds it samples, CI
/// pins its behavior.
struct MeetingDetectionPolicy {

    enum Event: Equatable {
        case started(MeetingApp)
        case ended(MeetingApp)
    }

    var startDelay: TimeInterval = 3
    var endGrace: TimeInterval = 15
    /// Start delay while a camera is running: mic + camera together is a
    /// much stronger "video call" signal, so prompt sooner.
    var cameraStartDelay: TimeInterval = 1

    /// The meeting currently in progress, if any.
    private(set) var current: MeetingApp?
    private var candidate: (app: MeetingApp, since: Date)?
    private var lastSeen: Date?

    init(startDelay: TimeInterval = 3, endGrace: TimeInterval = 15, cameraStartDelay: TimeInterval = 1) {
        self.startDelay = startDelay
        self.endGrace = endGrace
        self.cameraStartDelay = cameraStartDelay
    }

    /// Feeds one sample. Returns at most one event.
    ///
    /// - Parameter cameraInUse: Whether any camera is running right now; when
    ///   it is, the meeting starts after `cameraStartDelay` instead of
    ///   `startDelay` (whichever is shorter).
    mutating func update(active: [MeetingApp], now: Date, cameraInUse: Bool = false) -> Event? {
        guard let primary = Self.primary(of: active) else {
            candidate = nil
            if let meeting = current, let lastSeen, now.timeIntervalSince(lastSeen) >= endGrace {
                current = nil
                self.lastSeen = nil
                return .ended(meeting)
            }
            return nil
        }

        lastSeen = now
        guard current == nil else { return nil }

        // Keep the original start time while the same app holds the mic.
        if candidate.map({ !active.contains($0.app) }) ?? true {
            candidate = (primary, now)
        }
        let delay = cameraInUse ? min(startDelay, cameraStartDelay) : startDelay
        guard let candidate, now.timeIntervalSince(candidate.since) >= delay else { return nil }
        current = candidate.app
        self.candidate = nil
        return .started(candidate.app)
    }

    /// Forgets all state (e.g. when detection is turned off).
    mutating func reset() {
        current = nil
        candidate = nil
        lastSeen = nil
    }

    /// The app to attribute the meeting to when several hold the mic: a
    /// dedicated conferencing app beats a browser beats anything else; ties
    /// break by name so the choice is stable across samples.
    static func primary(of active: [MeetingApp]) -> MeetingApp? {
        active.min { lhs, rhs in
            let l = rank(lhs.kind), r = rank(rhs.kind)
            return l != r ? l < r : lhs.name < rhs.name
        }
    }

    private static func rank(_ kind: MeetingApp.Kind) -> Int {
        switch kind {
        case .conferencing: return 0
        case .browser:      return 1
        case .other:        return 2
        }
    }
}
