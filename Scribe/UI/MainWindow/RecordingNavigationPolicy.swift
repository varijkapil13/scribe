// Scribe/UI/MainWindow/RecordingNavigationPolicy.swift
import Foundation

/// Decides whether `MainWindowView`'s sidebar selection should flip to
/// `.live` when `AppState.isTranscribing` becomes `true`.
///
/// Lives outside the view body so the rules can be exercised without
/// SwiftUI. The pair of rules covered here are exactly the ones the
/// auto-create-meeting-note path depends on (review item #7):
///
///   1. If the user is already viewing a Note, the note's inline
///      `NoteLiveRecordingPane` handles streaming — don't navigate away.
///   2. If `AppDelegate` just posted `.scribeRequestNavigateToNote` (auto-
///      create path), `currentSelection` will be a `.note(id)` by the
///      time this policy runs, so rule (1) covers that case too.
///   3. Recording stopped (`isRecording == false`): no navigation.
///   4. Recording started anywhere else: jump to `.live`.
enum RecordingNavigationPolicy {

    /// Returns the destination the view should navigate to, or `nil` if
    /// no navigation is warranted.
    static func destination(
        currentSelection: MainSelection?,
        isRecording: Bool
    ) -> MainSelection? {
        guard isRecording else { return nil }
        if case .note = currentSelection { return nil }
        return .live
    }

    /// Returns the transcript destination to navigate to when a recording
    /// stops, or `nil` if no navigation is warranted.
    ///
    /// Only the user who was watching the live view (which goes blank once the
    /// session ends) is taken to the finished transcript; anyone who browsed
    /// off to a note/task/etc. is left where they are. Requires a non-nil
    /// finished session id.
    static func stopDestination(
        currentSelection: MainSelection?,
        finishedSessionId: String?
    ) -> MainSelection? {
        guard currentSelection == .live, let finishedSessionId else { return nil }
        return .session(finishedSessionId)
    }
}
