import CoreGraphics
import XCTest
@testable import Scribe

final class QuickCaptureComposerTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return utcCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Detector-free parse so results don't depend on today's date.
    private func parse(_ line: String) -> QuickAddParser.ParsedQuickAdd {
        QuickAddParser.parse(line, detector: nil)
    }

    // MARK: - Mode

    func testShortcutDigitsMapToModes() {
        XCTAssertEqual(QuickCaptureMode.mode(forShortcutDigit: 1), .note)
        XCTAssertEqual(QuickCaptureMode.mode(forShortcutDigit: 2), .task)
        XCTAssertEqual(QuickCaptureMode.mode(forShortcutDigit: 3), .appendToDaily)
        XCTAssertNil(QuickCaptureMode.mode(forShortcutDigit: 4))
        XCTAssertEqual(QuickCaptureMode.allCases.map(\.shortcutDigit), [1, 2, 3])
    }

    func testRestoredModeFallsBackToNote() {
        XCTAssertEqual(QuickCaptureMode.restored(from: "task"), .task)
        XCTAssertEqual(QuickCaptureMode.restored(from: "appendToDaily"), .appendToDaily)
        XCTAssertEqual(QuickCaptureMode.restored(from: "bogus"), .note)
        XCTAssertEqual(QuickCaptureMode.restored(from: nil), .note)
    }

    // MARK: - Request

    func testBlankTextBuildsNoRequestInAnyMode() {
        for mode in QuickCaptureMode.allCases {
            XCTAssertNil(QuickCaptureComposer.request(mode: mode, text: "  \n\t ", parse: parse), "\(mode)")
            XCTAssertFalse(QuickCaptureComposer.canSave(mode: mode, text: "", parse: parse))
        }
    }

    func testNoteRequestSplitsTitleAndBody() {
        let request = QuickCaptureComposer.request(
            mode: .note,
            text: "  Offsite ideas\nBoat trip\n\nKaraoke  \n",
            parse: parse
        )
        XCTAssertEqual(request, .note(title: "Offsite ideas", body: "Boat trip\n\nKaraoke"))
    }

    func testNoteTitleDropsHeadingMarker() {
        XCTAssertEqual(QuickCaptureComposer.noteParts(from: "## Plan").title, "Plan")
        XCTAssertEqual(QuickCaptureComposer.noteParts(from: "## Plan").body, "")
        XCTAssertEqual(QuickCaptureComposer.noteParts(from: "#idea boat trip").title, "#idea boat trip")
    }

    func testLongFirstLineKeepsFullTextInBody() {
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let parts = QuickCaptureComposer.noteParts(from: long)
        XCTAssertLessThanOrEqual(parts.title.count, QuickCaptureComposer.maxTitleLength)
        XCTAssertTrue(parts.title.hasSuffix("\u{2026}"))
        XCTAssertEqual(parts.body, long)
    }

    func testTaskRequestUsesParsedFirstLineAndNotesFromRest() {
        let request = QuickCaptureComposer.request(
            mode: .task,
            text: "Buy milk #shopping +Errands !high\noat, not dairy",
            parse: parse
        )
        let expected = QuickCaptureTaskDraft(
            title: "Buy milk",
            notes: "oat, not dairy",
            projectName: "Errands",
            priority: .high,
            dueAt: nil,
            tags: ["shopping"]
        )
        XCTAssertEqual(request, .task(expected))
    }

    func testTaskWithOnlyMetadataIsNotSavable() {
        XCTAssertNil(QuickCaptureComposer.request(mode: .task, text: "#errands !high", parse: parse))
        XCTAssertFalse(QuickCaptureComposer.canSave(mode: .task, text: "#errands !high", parse: parse))
        // The same text is a fine note.
        XCTAssertTrue(QuickCaptureComposer.canSave(mode: .note, text: "#errands !high", parse: parse))
    }

    func testAppendRequestKeepsTrimmedText() {
        XCTAssertEqual(
            QuickCaptureComposer.request(mode: .appendToDaily, text: "\n Call Anna \n", parse: parse),
            .appendToDaily(text: "Call Anna")
        )
    }

    // MARK: - Daily entry

    func testDailyEntryIsTimestampedBullet() {
        let entry = QuickCaptureComposer.dailyEntry(text: "Call Anna", at: date(2026, 10, 10, 14, 5), timeZone: utc)
        XCTAssertEqual(entry, "- 14:05 Call Anna")
    }

    func testDailyEntryIndentsContinuationLines() {
        let entry = QuickCaptureComposer.dailyEntry(
            text: "Call Anna\nbring the budget sheet",
            at: date(2026, 10, 10, 9, 0),
            timeZone: utc
        )
        XCTAssertEqual(entry, "- 09:00 Call Anna\n  bring the budget sheet")
    }

    func testAppendToEmptyBody() {
        XCTAssertEqual(QuickCaptureComposer.appendingDailyEntry("- 09:00 A", to: ""), "- 09:00 A\n")
        XCTAssertEqual(QuickCaptureComposer.appendingDailyEntry("- 09:00 A", to: " \n\n"), "- 09:00 A\n")
    }

    func testAppendAfterParagraphStartsNewBlock() {
        XCTAssertEqual(
            QuickCaptureComposer.appendingDailyEntry("- 09:00 A", to: "# Friday\n\nSome thoughts\n\n\n"),
            "# Friday\n\nSome thoughts\n\n- 09:00 A\n"
        )
    }

    func testAppendAfterListJoinsList() {
        XCTAssertEqual(
            QuickCaptureComposer.appendingDailyEntry("- 10:30 B", to: "- 09:00 A\n"),
            "- 09:00 A\n- 10:30 B\n"
        )
        XCTAssertEqual(
            QuickCaptureComposer.appendingDailyEntry("- 10:30 B", to: "- 09:00 A\n  more\n"),
            "- 09:00 A\n  more\n- 10:30 B\n"
        )
        XCTAssertEqual(
            QuickCaptureComposer.appendingDailyEntry("- 10:30 B", to: "- [ ] todo"),
            "- [ ] todo\n- 10:30 B\n"
        )
    }

    // MARK: - Dictation merge

    func testMergingDictationIntoTypedText() {
        XCTAssertEqual(QuickCaptureComposer.merging(typed: "", dictated: " Hello "), "Hello")
        XCTAssertEqual(QuickCaptureComposer.merging(typed: "Buy", dictated: "milk"), "Buy milk")
        XCTAssertEqual(QuickCaptureComposer.merging(typed: "Buy ", dictated: "milk"), "Buy milk")
        XCTAssertEqual(QuickCaptureComposer.merging(typed: "Buy", dictated: "  "), "Buy")
    }

    // MARK: - Chips

    func testChipsOrderAndKinds() {
        let now = date(2026, 10, 10, 8, 0)
        let parsed = QuickAddParser.ParsedQuickAdd(
            title: "Buy milk",
            tags: ["shopping", "home"],
            priority: .high,
            projectName: "errands",
            dueAt: date(2026, 10, 11)
        )
        let chips = QuickCaptureComposer.chips(for: parsed, knownProjects: ["Errands"], now: now, calendar: utcCalendar)
        XCTAssertEqual(chips.map(\.kind), [.due, .priority, .project, .tag, .tag])
        XCTAssertEqual(chips.map(\.text), ["Tomorrow", "High", "Errands", "shopping", "home"])
    }

    func testUnknownProjectChipSaysInbox() {
        let parsed = QuickAddParser.ParsedQuickAdd(title: "x", tags: [], priority: nil, projectName: "Nope", dueAt: nil)
        let chips = QuickCaptureComposer.chips(for: parsed, knownProjects: ["Work"], now: Date(), calendar: utcCalendar)
        XCTAssertEqual(chips.map(\.kind), [.unknownProject])
        XCTAssertTrue(chips.first?.text.contains("Inbox") ?? false)

        let unknownList = QuickCaptureComposer.chips(for: parsed, knownProjects: nil, now: Date(), calendar: utcCalendar)
        XCTAssertEqual(unknownList, [QuickCaptureChip(kind: .project, text: "Nope")])
    }

    func testNoMetadataNoChips() {
        let parsed = QuickAddParser.ParsedQuickAdd(title: "x", tags: [], priority: nil, projectName: nil, dueAt: nil)
        XCTAssertTrue(QuickCaptureComposer.chips(for: parsed, knownProjects: [], now: Date(), calendar: utcCalendar).isEmpty)
    }

    func testDueTextRelativeDays() {
        let now = date(2026, 10, 10, 8, 0)
        XCTAssertEqual(QuickCaptureComposer.dueText(date(2026, 10, 10), now: now, calendar: utcCalendar), "Today")
        XCTAssertEqual(QuickCaptureComposer.dueText(date(2026, 10, 11), now: now, calendar: utcCalendar), "Tomorrow")
        XCTAssertEqual(QuickCaptureComposer.dueText(date(2026, 10, 9), now: now, calendar: utcCalendar), "Yesterday")
        XCTAssertTrue(QuickCaptureComposer.dueText(date(2026, 10, 10, 17, 0), now: now, calendar: utcCalendar).hasPrefix("Today "))
        let later = QuickCaptureComposer.dueText(date(2026, 10, 20), now: now, calendar: utcCalendar)
        XCTAssertFalse(later.isEmpty)
        XCTAssertNotEqual(later, "Today")
    }

    // MARK: - Confirmation

    func testConfirmationMessages() {
        XCTAssertEqual(
            QuickCaptureComposer.confirmation(for: .note(title: "a", body: ""), resolvedProject: nil),
            "Note saved to Inbox"
        )
        let draft = QuickCaptureTaskDraft(title: "a", notes: "", projectName: "Nope", priority: nil, dueAt: nil, tags: [])
        XCTAssertEqual(QuickCaptureComposer.confirmation(for: .task(draft), resolvedProject: nil), "Task added to Inbox")
        XCTAssertEqual(QuickCaptureComposer.confirmation(for: .task(draft), resolvedProject: "Work"), "Task added to Work")
        XCTAssertEqual(
            QuickCaptureComposer.confirmation(for: .appendToDaily(text: "a"), resolvedProject: nil),
            "Added to today's daily note"
        )
    }

    // MARK: - Geometry

    func testPanelIsCentredAThirdDown() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let origin = QuickCapturePanelGeometry.origin(panelSize: CGSize(width: 600, height: 150), visibleFrame: visible)
        XCTAssertEqual(origin.x, 300)
        // Top edge at 900 - 300 = 600 → origin.y = 450.
        XCTAssertEqual(origin.y, 450)
    }

    func testPanelStaysOnSecondaryScreen() {
        let visible = CGRect(x: -1440, y: 100, width: 1440, height: 300)
        let size = CGSize(width: 600, height: 280)
        let origin = QuickCapturePanelGeometry.origin(panelSize: size, visibleFrame: visible)
        XCTAssertEqual(origin.x, -1020)
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY)
        XCTAssertLessThanOrEqual(origin.y + size.height, visible.maxY)
    }
}
