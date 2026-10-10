// ScribeiOS/Recording/LiveActivityShared/ScribeRecordingActivityAttributes.swift
//
// Compiled into BOTH the ScribeiOS app (via `sources: ScribeiOS/`) and the
// ScribeRecordingActivity widget extension (listed by path in project.yml):
// the app starts / updates the Live Activity, the extension renders it on the
// Lock Screen and in the Dynamic Island. Keep it free of app-only types.

import ActivityKit
import Foundation

/// The Live Activity of an iPhone / iPad recording.
struct ScribeRecordingActivityAttributes: ActivityAttributes, Sendable {

    struct ContentState: Codable, Hashable, Sendable {
        /// `now − elapsed` while recording, so `Text(timerStart, style: .timer)`
        /// counts the recording's active time (pauses excluded).
        var timerStart: Date
        /// Active seconds so far — what a paused recording shows.
        var elapsedSeconds: Double
        var isPaused: Bool
        /// The latest transcript line (Lock Screen / expanded island), may be
        /// empty.
        var latestLine: String
    }

    /// The meeting note's title.
    var title: String
    /// The recording's session id (tapping the activity opens it).
    var sessionId: String
}

extension ScribeRecordingActivityAttributes.ContentState {

    /// "12:34" / "1:02:03".
    var elapsedLabel: String {
        let total = elapsedSeconds.isFinite ? max(0, Int(elapsedSeconds)) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension ScribeRecordingActivityAttributes {

    /// `scribe://meeting/<sessionId>` — opens the recording in the app.
    var openURL: URL? {
        URL(string: "scribe://meeting/\(sessionId)")
    }
}
