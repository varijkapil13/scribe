import Foundation

/// Remembers which recording meeting detection itself started, so "stop
/// recording automatically when the meeting ends" never stops a recording the
/// user started by hand.
///
/// Ownership is tied to the recording's session id: if the user stops the
/// auto-started recording and starts another one during the same call, the
/// new one is theirs.
struct MeetingRecordingOwnership: Equatable, Sendable {

    /// What to do with a running recording once the detected meeting ends.
    enum EndResponse: Equatable, Sendable {
        /// Leave the recording alone, say nothing.
        case ignore
        /// Offer to stop (notification with a Stop action).
        case ask
        /// Stop the recording.
        case stop
    }

    /// Session id of the recording detection started, if any.
    private(set) var detectorSessionId: String?

    /// Records that detection just started the recording `sessionId`.
    mutating func detectorStarted(sessionId: String?) {
        detectorSessionId = sessionId
    }

    /// Forgets the recording (it stopped, or the meeting ended).
    mutating func clear() {
        detectorSessionId = nil
    }

    /// Whether detection started the recording that is running now.
    func ownsRecording(currentSessionId: String?) -> Bool {
        guard let detectorSessionId, let currentSessionId else { return false }
        return detectorSessionId == currentSessionId
    }

    /// The reaction to a meeting ending. "Stop automatically" only applies
    /// to recordings detection started; for manual ones it degrades to
    /// asking.
    func endResponse(
        endAction: MeetingEndAction,
        isRecording: Bool,
        currentSessionId: String?
    ) -> EndResponse {
        guard isRecording else { return .ignore }
        switch endAction {
        case .nothing:
            return .ignore
        case .notify:
            return .ask
        case .stop:
            return ownsRecording(currentSessionId: currentSessionId) ? .stop : .ask
        }
    }
}

/// How often meeting detection re-samples mic usage when nothing tells it to.
///
/// Detection is event-driven (CoreAudio property listeners); the poll is only
/// a safety net for missed notifications, so it is slow, and slower still in
/// Low Power Mode. When the listeners couldn't be installed, polling is the
/// only signal and runs faster.
enum MeetingDetectionSchedule {

    /// Delay between a CoreAudio change notification and the sample, so a
    /// burst of notifications (an app opening several streams) is read once.
    static let debounce: Duration = .milliseconds(400)

    /// Safety-net poll interval in seconds.
    nonisolated static func fallbackInterval(lowPowerMode: Bool, listenersActive: Bool) -> TimeInterval {
        switch (listenersActive, lowPowerMode) {
        case (true, false):  return 15
        case (true, true):   return 60
        case (false, false): return 3
        case (false, true):  return 10
        }
    }

    /// Timer tolerance: a generous fraction of the interval lets macOS
    /// coalesce wake-ups.
    nonisolated static func tolerance(for interval: TimeInterval) -> TimeInterval {
        max(0.5, interval * 0.25)
    }
}
