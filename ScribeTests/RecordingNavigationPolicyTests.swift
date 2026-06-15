// ScribeTests/RecordingNavigationPolicyTests.swift
import XCTest
@testable import Scribe

/// Pins the "should we flip the sidebar to .live when recording starts?"
/// rule extracted from `MainWindowView.onChange(of:isTranscribing)`.
/// Review item #7 was specifically about this flip; the rules below
/// encode the fix and prevent regression.
final class RecordingNavigationPolicyTests: XCTestCase {

    func testRecordingStartedFromNothingFlipsToLive() {
        let dest = RecordingNavigationPolicy.destination(
            currentSelection: nil,
            isRecording: true
        )
        XCTAssertEqual(dest, .live)
    }

    func testRecordingStartedFromTasksFlipsToLive() {
        let dest = RecordingNavigationPolicy.destination(
            currentSelection: .tasks(.inbox),
            isRecording: true
        )
        XCTAssertEqual(dest, .live)
    }

    func testRecordingStartedInsideANoteStaysOnTheNote() {
        // Critical for the inline live-pane experience. If we flipped to
        // .live here the user's freeform typing surface would disappear
        // mid-meeting.
        let dest = RecordingNavigationPolicy.destination(
            currentSelection: .note("n1"),
            isRecording: true
        )
        XCTAssertNil(dest)
    }

    func testRecordingStartedAfterAutoCreateStaysOnNewNote() {
        // Auto-create path: AppDelegate posted .scribeRequestNavigateToNote
        // before flipping isTranscribing, so by the time this policy runs
        // currentSelection is already the new note. Skipping the flip
        // is what eliminates the brief flash to LiveSessionView.
        let dest = RecordingNavigationPolicy.destination(
            currentSelection: .note("auto-created"),
            isRecording: true
        )
        XCTAssertNil(dest)
    }

    func testRecordingStoppedNeverNavigates() {
        // The `destination` (start) policy never navigates on a stop
        // transition; the dedicated `stopDestination` policy owns that case.
        XCTAssertNil(RecordingNavigationPolicy.destination(
            currentSelection: .live, isRecording: false
        ))
        XCTAssertNil(RecordingNavigationPolicy.destination(
            currentSelection: .note("n1"), isRecording: false
        ))
        XCTAssertNil(RecordingNavigationPolicy.destination(
            currentSelection: nil, isRecording: false
        ))
    }

    // MARK: - Stop navigation

    func testStoppedFromLiveNavigatesToFinishedTranscript() {
        // The live view goes blank when the session ends, so a user watching
        // it is taken straight to the finished transcript.
        let dest = RecordingNavigationPolicy.stopDestination(
            currentSelection: .live,
            finishedSessionId: "s1"
        )
        XCTAssertEqual(dest, .session("s1"))
    }

    func testStoppedFromANoteStaysPut() {
        // Anyone who browsed off to a note keeps their context; we don't yank
        // them to the transcript.
        let dest = RecordingNavigationPolicy.stopDestination(
            currentSelection: .note("n1"),
            finishedSessionId: "s1"
        )
        XCTAssertNil(dest)
    }

    func testStoppedWithNoFinishedSessionDoesNotNavigate() {
        // No session id (e.g. a recording that never created one) → nowhere to
        // navigate, even from the live view.
        let dest = RecordingNavigationPolicy.stopDestination(
            currentSelection: .live,
            finishedSessionId: nil
        )
        XCTAssertNil(dest)
    }
}
