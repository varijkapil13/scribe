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
        // The previous codebase used to auto-navigate to the most-recent
        // transcript on stop. That behaviour is gone; the policy must
        // return nil for every "stopped" transition.
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
}
