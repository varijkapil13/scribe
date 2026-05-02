import XCTest
@testable import Scribe

/// Tests for `SpeechErrorClassifier` — pure-function categorization that
/// drives whether the UI shows a banner or a guided modal. Decoupled from
/// AppDelegate so we can verify the matcher without spinning up AppKit.
final class SpeechErrorClassifierTests: XCTestCase {

    private func error(_ message: String) -> Error {
        NSError(domain: "TestSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func testSiriAndDictationDisabledMessageIsClassified() {
        let cases = [
            "Siri and Dictation are disabled",
            "Both Siri & Dictation must be enabled",
            "siri / dictation off",
            "Please enable Siri or Dictation in System Settings",
        ]
        for message in cases {
            XCTAssertEqual(
                SpeechErrorClassifier.category(for: error(message)),
                .siriOrDictationDisabled,
                "Expected siriOrDictationDisabled for: \(message)"
            )
        }
    }

    func testGenericErrorIsClassifiedAsGeneric() {
        let cases = [
            "Network unavailable",
            "Out of memory",
            "Permission denied",
            "Unknown speech model state",
            "Dictation only",         // missing 'siri'
            "Siri tip of the day",    // missing 'dictation'
        ]
        for message in cases {
            XCTAssertEqual(
                SpeechErrorClassifier.category(for: error(message)),
                .generic,
                "Expected generic for: \(message)"
            )
        }
    }

    func testEmptyMessageDefaultsToGeneric() {
        XCTAssertEqual(SpeechErrorClassifier.category(for: error("")), .generic)
    }
}
