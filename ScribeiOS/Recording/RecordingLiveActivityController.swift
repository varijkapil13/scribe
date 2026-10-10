// ScribeiOS/Recording/RecordingLiveActivityController.swift
//
// Starts, updates and ends the recording's Live Activity (Lock Screen +
// Dynamic Island, rendered by the ScribeRecordingActivity extension). Every
// ActivityKit call is in this file so an SDK change is a one-file fix.
// Degrades to a no-op when Live Activities are off (Settings, or the user
// disabled them for Scribe) or unsupported (CI simulator builds, iPad).

// `@preconcurrency`: if the SDK's `Activity` isn't annotated Sendable, handing
// it to its own async `update` / `end` from the main actor is still fine (it
// is only ever used from here).
@preconcurrency import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityController {

    private var activity: Activity<ScribeRecordingActivityAttributes>?
    private var lastState: ScribeRecordingActivityAttributes.ContentState?

    var isActive: Bool { activity != nil }

    /// Ends activities left over from a previous run (the app was killed
    /// while recording).
    func endStaleActivities() {
        for stale in Activity<ScribeRecordingActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(title: String, sessionId: String, state: ScribeRecordingActivityAttributes.ContentState) {
        guard activity == nil, MobileRecordingSettings.liveActivity,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ScribeRecordingActivityAttributes(title: title, sessionId: sessionId)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            Log.app.error("Couldn't start the recording Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pushes `state` (skipped when unchanged — the system budgets updates).
    func update(_ state: ScribeRecordingActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    func end(_ state: ScribeRecordingActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}
