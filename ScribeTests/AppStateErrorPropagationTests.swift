import XCTest
@testable import Scribe

/// Verifies that `AppState.lastError` is populated whenever the storage layer
/// or the speech engine fails — exercises the user-visible error-banner
/// pipeline end-to-end, including the AppDelegate-style wrapping pattern that
/// previously clobbered AppState's handler.
@MainActor
final class AppStateErrorPropagationTests: XCTestCase {

    func testFailedSegmentInsertSurfacesAsLastError() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TranscriptStore(databaseManager: manager)
        let state = AppState(transcriptStore: store)

        // Point at a session id that doesn't exist → segment insert fails the
        // foreign-key check and `flushPendingSegment` should record the error.
        state.currentSessionId = "no-such-session"
        let segment = TranscriptionSegment(
            id: UUID(),
            sessionOffsetMs: 0,
            startMs: 0,
            endMs: 1_000,
            speaker: "you",
            text: "this should fail to persist"
        )
        state.ingestTranscribedSegment(segment)

        XCTAssertNil(state.lastError)
        state.flushPendingSegment()

        let errorMessage = try XCTUnwrap(state.lastError)
        XCTAssertTrue(errorMessage.contains("Failed to save segment"),
                      "got: \(errorMessage)")
    }

    /// Reproduces the bug AppDelegate previously had: setting the speech
    /// engine's `onSessionError` directly clobbered AppState's handler,
    /// breaking the banner. The fix is to *wrap* the existing handler.
    func testSpeechEngineErrorWithWrappedHandlerStillUpdatesLastError() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TranscriptStore(databaseManager: manager)
        let state = AppState(transcriptStore: store)

        var delegateInvocations = 0
        // Mirror the AppDelegate.observeSpeechErrors() wrapping pattern.
        let stateHandler = state.speechEngine.onSessionError
        state.speechEngine.onSessionError = { error in
            stateHandler?(error)
            delegateInvocations += 1
        }

        let speechError = NSError(
            domain: "Speech",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Engine exploded"]
        )
        state.speechEngine.onSessionError?(speechError)

        XCTAssertEqual(state.lastError, "Engine exploded")
        XCTAssertEqual(delegateInvocations, 1)
    }
}
