// ScribeTests/NoteTemplateRendererTests.swift
import XCTest
@testable import Scribe

final class NoteTemplateRendererTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    /// Saturday 10 October 2026, 14:05:00 UTC.
    private var date: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 10
        components.hour = 14
        components.minute = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: components)!
    }

    private func context(title: String = "Weekly Review",
                         meetingTitle: String? = nil,
                         attendees: [String] = [],
                         clipboard: String? = nil) -> NoteTemplateContext {
        NoteTemplateContext(date: date, title: title, meetingTitle: meetingTitle,
                            meetingAttendees: attendees, clipboard: clipboard,
                            locale: posix, timeZone: utc)
    }

    func testDateTimeWeekdayAndTitle() {
        let rendered = NoteTemplateRenderer.render(
            "# {{title}}\n{{date}} {{time}} {{weekday}}",
            context: context()
        )
        XCTAssertEqual(rendered.text, "# Weekly Review\n2026-10-10 14:05 Saturday")
        XCTAssertNil(rendered.cursorOffset)
    }

    func testCustomDateFormat() {
        let rendered = NoteTemplateRenderer.render("{{date:dd/MM/yyyy}} · {{ date : yyyy }}", context: context())
        XCTAssertEqual(rendered.text, "10/10/2026 · 2026")
    }

    func testTimeFormatArgument() {
        XCTAssertEqual(NoteTemplateRenderer.render("{{time:h:mm a}}", context: context()).text, "2:05 PM")
    }

    func testNamesAreCaseInsensitive() {
        XCTAssertEqual(NoteTemplateRenderer.render("{{TITLE}} {{Date}}", context: context()).text,
                       "Weekly Review 2026-10-10")
    }

    func testMeetingVariables() {
        let rendered = NoteTemplateRenderer.render(
            "{{meeting.title}} with {{meeting.attendees}}",
            context: context(meetingTitle: "Design Sync", attendees: ["Ana", " ", "Ben "])
        )
        XCTAssertEqual(rendered.text, "Design Sync with Ana, Ben")
    }

    func testMeetingVariablesEmptyWithoutMeeting() {
        XCTAssertEqual(NoteTemplateRenderer.render("[{{meeting.title}}|{{meeting.attendees}}]",
                                                   context: context()).text, "[|]")
    }

    func testClipboard() {
        XCTAssertEqual(NoteTemplateRenderer.render("> {{clipboard}}", context: context(clipboard: "pasted")).text,
                       "> pasted")
        XCTAssertEqual(NoteTemplateRenderer.render("> {{clipboard}}", context: context()).text, "> ")
    }

    func testCursorIsRemovedAndOffsetRecorded() {
        let rendered = NoteTemplateRenderer.render("# {{title}}\n\n{{cursor}}\nend", context: context())
        XCTAssertEqual(rendered.text, "# Weekly Review\n\n\nend")
        XCTAssertEqual(rendered.cursorOffset, ("# Weekly Review\n\n" as NSString).length)
    }

    func testOnlyFirstCursorCounts() {
        let rendered = NoteTemplateRenderer.render("a{{cursor}}b{{cursor}}c", context: context())
        XCTAssertEqual(rendered.text, "abc")
        XCTAssertEqual(rendered.cursorOffset, 1)
    }

    func testCursorOffsetIsUTF16() {
        let rendered = NoteTemplateRenderer.render("🎉{{cursor}}", context: context())
        XCTAssertEqual(rendered.cursorOffset, 2)
    }

    func testUnknownVariablesAreKept() {
        let rendered = NoteTemplateRenderer.render("{{unknown}} {{date}} {{ nope:x }}", context: context())
        XCTAssertEqual(rendered.text, "{{unknown}} 2026-10-10 {{ nope:x }}")
    }

    func testTemplateWithoutVariablesIsUnchanged() {
        let rendered = NoteTemplateRenderer.render("plain { text }", context: context())
        XCTAssertEqual(rendered, RenderedNoteTemplate(text: "plain { text }", cursorOffset: nil))
    }

    func testTrimmedForNoteBodyShiftsCursor() {
        let trimmed = NoteTemplateRenderer.trimmedForNoteBody(
            RenderedNoteTemplate(text: "\n\nHello\n\n", cursorOffset: 4)
        )
        XCTAssertEqual(trimmed.text, "Hello")
        XCTAssertEqual(trimmed.cursorOffset, 2)
    }

    func testTrimmedForNoteBodyClampsCursor() {
        let trimmed = NoteTemplateRenderer.trimmedForNoteBody(
            RenderedNoteTemplate(text: "\nHi\n\n", cursorOffset: 5)
        )
        XCTAssertEqual(trimmed.text, "Hi")
        XCTAssertEqual(trimmed.cursorOffset, 2)
    }

    func testAppendingDraftToSeed() {
        XCTAssertEqual(NoteTemplateRenderer.appendingDraft("x", toSeed: "# Day\n\n"), "# Day\n\nx")
        XCTAssertEqual(NoteTemplateRenderer.appendingDraft("x", toSeed: "  \n"), "x")
        XCTAssertEqual(NoteTemplateRenderer.appendingDraft("", toSeed: "# Day"), "# Day")
    }

    // MARK: - Library

    func testSanitizedFolder() {
        XCTAssertEqual(NoteTemplateSettings.sanitizedFolder("/Templates/"), "Templates")
        XCTAssertEqual(NoteTemplateSettings.sanitizedFolder("Areas/Templates"), "Areas/Templates")
        XCTAssertEqual(NoteTemplateSettings.sanitizedFolder("../outside"), NoteTemplateSettings.defaultFolder)
        XCTAssertEqual(NoteTemplateSettings.sanitizedFolder(".hidden"), NoteTemplateSettings.defaultFolder)
        XCTAssertEqual(NoteTemplateSettings.sanitizedFolder("   "), NoteTemplateSettings.defaultFolder)
    }

    func testLibraryListsTemplatesExcludingSummariesAndRecipes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Summaries"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Recipes"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Work"),
                                                withIntermediateDirectories: true)
        try "---\nid: abc\ntitle: Daily\n---\n# {{date}}\n".write(
            to: folder.appendingPathComponent("Daily.md"), atomically: true, encoding: .utf8)
        try "Standup".write(to: folder.appendingPathComponent("Work/Standup.md"), atomically: true, encoding: .utf8)
        try "summary".write(to: folder.appendingPathComponent("Summaries/S.md"), atomically: true, encoding: .utf8)
        try "recipe".write(to: folder.appendingPathComponent("Recipes/R.md"), atomically: true, encoding: .utf8)
        try "not md".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let library = NoteTemplateLibrary(vaultRoot: NotesDirectory(root: root).root, folder: "Templates")
        let files = library.list()
        XCTAssertEqual(files.map(\.name), ["Daily", "Work/Standup"])
        XCTAssertEqual(files.first?.id, "Templates/Daily.md")

        // Frontmatter is stripped from the template body.
        XCTAssertEqual(library.load(id: "Templates/Daily.md"), "# {{date}}")
        XCTAssertNil(library.load(id: "../escape.md"))
        XCTAssertNil(library.load(id: "Templates/Missing.md"))

        let rendered = library.render(id: "Templates/Work/Standup.md", context: context())
        XCTAssertEqual(rendered?.text, "Standup")
        XCTAssertNil(library.render(id: "", context: context()))
    }
}
