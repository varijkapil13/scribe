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
        // Auto-create path: the new note is routed in as the current
        // destination (see autoCreateDestination), so by the time this policy
        // runs currentSelection is already the new note. Skipping the flip
        // is what eliminates the brief flash to LiveSessionView.
        let dest = RecordingNavigationPolicy.destination(
            currentSelection: .note("auto-created"),
            isRecording: true
        )
        XCTAssertNil(dest)
    }

    // MARK: - Auto-create atomic transition (B1.1)

    func testAutoCreateDestinationIsTheNewNote() {
        // The auto-create transition is a policy decision, not an implicit
        // notification-ordering contract: it resolves to the new note so the
        // view can apply it as one routed `replaceCurrent` step.
        XCTAssertEqual(
            RecordingNavigationPolicy.autoCreateDestination(noteId: "auto-created"),
            .note("auto-created")
        )
    }

    @MainActor
    func testAutoCreatePathNeverShowsAnIntermediateLiveFrame() {
        // End-to-end timing pin for B1.1. Drive the exact coordinator
        // sequence the window performs on the auto-create→record path and
        // record every value `current` takes, then assert `.live` never
        // appears as an intermediate frame.
        //
        // The user starts a global recording with no note open (e.g. on
        // .today). AppDelegate auto-creates a note and the window routes it
        // atomically; then `startSession` flips `isTranscribing` and the
        // policy runs against the already-updated selection.
        let nav = NavigationCoordinator(current: .today)

        var frames: [MainSelection] = [nav.current]
        let recordFrame = { frames.append(nav.current) }

        // 1. Auto-create routes the new note in as a single atomic transition.
        nav.replaceCurrent(
            RecordingNavigationPolicy.autoCreateDestination(noteId: "auto-created")
        )
        recordFrame()

        // 2. `isTranscribing` flips true; the start policy runs. Because the
        //    note is already current it must NOT navigate to .live.
        if let dest = RecordingNavigationPolicy.destination(
            currentSelection: nav.current,
            isRecording: true
        ) {
            nav.navigate(to: dest)
        }
        recordFrame()

        XCTAssertFalse(
            frames.contains(.live),
            "Auto-create path must never produce an intermediate .live frame; saw \(frames)"
        )
        XCTAssertEqual(nav.current, .note("auto-created"))
        // And no spurious Back entry was created for the auto-created note.
        XCTAssertFalse(nav.canGoBack)
    }

    @MainActor
    func testAutoCreateIsRobustToReorderedCallbacks() {
        // Defense-in-depth: even if SwiftUI delivered the `isTranscribing`
        // flip BEFORE the navigate transition (the reordering the old
        // post-before-flip contract feared), the worst case is a single
        // pre-create .live frame that the atomic replace immediately
        // supersedes — never a flash *after* the note is shown. Here we prove
        // the atomic replace still lands the user on the note.
        let nav = NavigationCoordinator(current: .today)

        // Hypothetical reordering: policy runs first (no note yet) → .live.
        if let dest = RecordingNavigationPolicy.destination(
            currentSelection: nav.current,
            isRecording: true
        ) {
            nav.navigate(to: dest)
        }
        // Then the atomic auto-create transition lands.
        nav.replaceCurrent(
            RecordingNavigationPolicy.autoCreateDestination(noteId: "auto-created")
        )

        XCTAssertEqual(nav.current, .note("auto-created"))
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
