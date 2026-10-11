import Foundation

/// Mac wiring for CloudKit meeting sync (Scribe/Sync/Meetings): after a round
/// imports or removes meetings, refresh the transcript lists and wake the
/// semantic index so remote meetings show up in Ask / search like local ones.
@MainActor
enum MeetingSyncMacBridge {

    /// Called once at launch (skipped for UI-test launches by the caller).
    static func start() {
        let scheduler = MeetingSyncScheduler.shared
        scheduler.onSessionsChanged = { sessionIds in
            for sessionId in sessionIds {
                NotificationCenter.default.post(name: .scribeSessionUpdated, object: sessionId)
            }
            SemanticIndexScheduler.shared.kick()
        }
        scheduler.start()
    }

    static func appDidBecomeActive() {
        MeetingSyncScheduler.shared.appDidBecomeActive()
    }
}
