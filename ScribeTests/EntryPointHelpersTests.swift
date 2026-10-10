// ScribeTests/EntryPointHelpersTests.swift
import XCTest
@testable import Scribe

/// Services-menu text parsing and Handoff activity mapping.
final class EntryPointHelpersTests: XCTestCase {

    // MARK: - SelectionCaptureParser: notes

    func testNoteFromSingleLine() {
        XCTAssertEqual(
            SelectionCaptureParser.noteFields(from: "  Buy a new keyboard  "),
            SelectionCaptureParser.NoteFields(title: "Buy a new keyboard", body: "Buy a new keyboard")
        )
    }

    func testNoteTitleIsFirstNonBlankLineWithoutHeadingMarker() {
        let text = "\n\n# Q4 Planning\n\n- ship it\n- celebrate\n"
        let fields = SelectionCaptureParser.noteFields(from: text)
        XCTAssertEqual(fields?.title, "Q4 Planning")
        XCTAssertEqual(fields?.body, "# Q4 Planning\n\n- ship it\n- celebrate")
    }

    func testBlankSelectionMakesNoNote() {
        XCTAssertNil(SelectionCaptureParser.noteFields(from: ""))
        XCTAssertNil(SelectionCaptureParser.noteFields(from: " \n\t\n "))
    }

    func testLongNoteTitleIsTruncatedAtAWordBoundary() {
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let fields = SelectionCaptureParser.noteFields(from: words)
        let title = fields?.title ?? ""
        XCTAssertLessThanOrEqual(title.count, SelectionCaptureParser.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.hasSuffix(" …"))
        XCTAssertTrue(title.dropLast().hasSuffix("word"))
        XCTAssertEqual(fields?.body, words)
    }

    func testLongTitleWithoutSpacesIsHardCut() {
        let blob = String(repeating: "x", count: 300)
        let title = SelectionCaptureParser.truncate(blob)
        XCTAssertEqual(title.count, SelectionCaptureParser.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // MARK: - SelectionCaptureParser: tasks

    func testTaskFromSingleLine() {
        XCTAssertEqual(
            SelectionCaptureParser.taskFields(from: "Email the design review notes"),
            SelectionCaptureParser.TaskFields(title: "Email the design review notes", notes: "")
        )
    }

    func testTaskRestOfSelectionBecomesNotes() {
        let fields = SelectionCaptureParser.taskFields(from: "- [ ] Follow up with Sam\nHe asked about pricing.\n\nAnd the timeline.")
        XCTAssertEqual(fields?.title, "Follow up with Sam")
        XCTAssertEqual(fields?.notes, "He asked about pricing.\n\nAnd the timeline.")
    }

    func testTaskStripsListMarkers() {
        XCTAssertEqual(SelectionCaptureParser.taskFields(from: "* Call the bank")?.title, "Call the bank")
        XCTAssertEqual(SelectionCaptureParser.taskFields(from: "3. Renew passport")?.title, "Renew passport")
        XCTAssertEqual(SelectionCaptureParser.taskFields(from: "> quoted thing")?.title, "quoted thing")
    }

    func testMarkerOnlyOrBlankSelectionMakesNoTask() {
        XCTAssertNil(SelectionCaptureParser.taskFields(from: "   "))
        XCTAssertNil(SelectionCaptureParser.taskFields(from: "#"))
    }

    func testTruncatedTaskTitleKeepsFullTextInNotes() {
        let long = Array(repeating: "step", count: 50).joined(separator: " ")
        let fields = SelectionCaptureParser.taskFields(from: long + "\nmore detail")
        XCTAssertTrue(fields?.title.hasSuffix("…") ?? false)
        XCTAssertEqual(fields?.notes, long + "\nmore detail")
    }

    func testNumbersThatAreNotListMarkersStay() {
        XCTAssertEqual(SelectionCaptureParser.stripMarkers("2026 budget review"), "2026 budget review")
        XCTAssertEqual(SelectionCaptureParser.stripMarkers("3.5 stars"), "3.5 stars")
    }

    // MARK: - ScribeUserActivity

    func testNoteActivityMapsToNote() {
        XCTAssertEqual(
            ScribeUserActivity.destination(activityType: ScribeUserActivity.viewNote, userInfo: ["id": "n-1"]),
            .note("n-1")
        )
    }

    func testTaskActivityMapsToTask() {
        XCTAssertEqual(
            ScribeUserActivity.destination(activityType: ScribeUserActivity.viewTask, userInfo: ["id": "t-1", "title": "Pay rent"]),
            .task("t-1")
        )
    }

    func testActivityWithoutIdOrForeignTypeIsIgnored() {
        XCTAssertNil(ScribeUserActivity.destination(activityType: ScribeUserActivity.viewNote, userInfo: nil))
        XCTAssertNil(ScribeUserActivity.destination(activityType: ScribeUserActivity.viewNote, userInfo: ["id": "  "]))
        XCTAssertNil(ScribeUserActivity.destination(activityType: ScribeUserActivity.viewNote, userInfo: ["id": 42]))
        XCTAssertNil(ScribeUserActivity.destination(activityType: "com.example.other", userInfo: ["id": "n-1"]))
    }

    func testActivityTypesMatchInfoPlistDeclaration() {
        XCTAssertEqual(ScribeUserActivity.allTypes, ["com.varij.scribe.viewNote", "com.varij.scribe.viewTask"])
    }

    func testConfiguredActivityRoundTrips() {
        let activity = NSUserActivity(activityType: ScribeUserActivity.viewNote)
        ScribeActivityPublisher.configure(activity, id: "n-9", title: "Roadmap")
        XCTAssertEqual(activity.title, "Roadmap")
        XCTAssertTrue(activity.isEligibleForHandoff)
        XCTAssertTrue(activity.isEligibleForSearch)
        XCTAssertEqual(
            ScribeUserActivity.destination(activityType: activity.activityType, userInfo: activity.userInfo),
            .note("n-9")
        )
    }

    // MARK: - EntryPointSettings

    func testSettingsDefaultToOnWhenUnset() {
        let suite = "EntryPointHelpersTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Couldn't create a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(EntryPointSettings.bool(EntryPointSettings.allowCaptureLinksKey, defaults: defaults))
        defaults.set(false, forKey: EntryPointSettings.allowCaptureLinksKey)
        XCTAssertFalse(EntryPointSettings.bool(EntryPointSettings.allowCaptureLinksKey, defaults: defaults))
    }
}
