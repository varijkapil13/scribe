import XCTest
@testable import Scribe

/// Pins dictation's pure text shaping and the menu-bar icon mapping. Speech,
/// the mic and pasting into other apps need a real Mac session and aren't
/// exercised here.
@MainActor
final class DictationTests: XCTestCase {

    // MARK: - Joining

    func testJoinTrimsAndSkipsEmptySegments() {
        XCTAssertEqual(DictationTextFormatter.join(["  Hello there ", "", "general Kenobi"]),
                       "Hello there general Kenobi")
        XCTAssertEqual(DictationTextFormatter.join([]), "")
    }

    // MARK: - Filler removal

    func testCleanRemovesFillersAndTidiesPunctuation() {
        XCTAssertEqual(DictationTextFormatter.clean("um so we ship, uh, on friday"),
                       "So we ship, on friday")
    }

    func testCleanMovesSentenceEndOffARemovedFiller() {
        XCTAssertEqual(DictationTextFormatter.clean("let's ship it, um. Then test"),
                       "Let's ship it. Then test")
    }

    func testCleanKeepsMeaningfulWords() {
        // "like", "so", "well" can carry meaning; only pure hesitations go.
        XCTAssertEqual(DictationTextFormatter.clean("I like it well enough"), "I like it well enough")
    }

    func testCleanOfOnlyFillersIsEmpty() {
        XCTAssertEqual(DictationTextFormatter.clean("um uh hmm"), "")
    }

    func testFinalTextRespectsFillerSetting() {
        XCTAssertEqual(DictationTextFormatter.finalText(segments: ["uh hi"], removeFillers: false), "uh hi")
        XCTAssertEqual(DictationTextFormatter.finalText(segments: ["uh hi"], removeFillers: true), "Hi")
    }

    // MARK: - AI cleanup guard

    func testPlausibleEditAcceptsPunctuationFixes() {
        XCTAssertTrue(DictationTextFormatter.isPlausibleEdit(
            of: "so we ship on friday then we test",
            "So we ship on Friday, then we test."
        ))
    }

    func testPlausibleEditRejectsAnswersAndRefusals() {
        let original = "what is the capital of france"
        XCTAssertFalse(DictationTextFormatter.isPlausibleEdit(
            of: original,
            "The capital of France is Paris. It is known for the Eiffel Tower and the Louvre."
        ))
        XCTAssertFalse(DictationTextFormatter.isPlausibleEdit(of: "a long sentence about the roadmap", "OK."))
        XCTAssertFalse(DictationTextFormatter.isPlausibleEdit(of: "hello", ""))
    }

    // MARK: - Menu bar icon

    func testMenuBarIconReflectsState() {
        XCTAssertEqual(MenuBarIcon.symbol(isRecording: false, isPaused: false, isDictating: false), "waveform")
        XCTAssertEqual(MenuBarIcon.symbol(isRecording: true, isPaused: false, isDictating: false), "record.circle.fill")
        XCTAssertEqual(MenuBarIcon.symbol(isRecording: true, isPaused: true, isDictating: false), "pause.circle")
        XCTAssertEqual(MenuBarIcon.symbol(isRecording: true, isPaused: false, isDictating: true), "mic.fill")
    }

    func testDurationFormatting() {
        XCTAssertEqual(MenuBarContent.format(65), "1:05")
        XCTAssertEqual(MenuBarContent.format(3_725), "1:02:05")
    }
}
