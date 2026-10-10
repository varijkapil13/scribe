// ScribeTests/WebEditorBridgeTests.swift
import XCTest
@testable import Scribe

final class WebEditorBridgeTests: XCTestCase {

    // MARK: - Commands

    func testNamedCommandJavaScript() {
        XCTAssertEqual(
            WebEditorCommand.find.javaScript,
            "window.scribeCommand && window.scribeCommand(\"find\", null);"
        )
        XCTAssertEqual(WebEditorCommand.findNext.name, "findNext")
        XCTAssertEqual(WebEditorCommand.findPrevious.name, "findPrevious")
        XCTAssertEqual(WebEditorCommand.replace.name, "replace")
        XCTAssertEqual(WebEditorCommand.named("foldAll"), WebEditorCommand.foldAll)
    }

    func testScrollToLineClampsToFirstLine() {
        XCTAssertEqual(WebEditorCommand.scrollToLine(12).argumentJSON, "12")
        XCTAssertEqual(WebEditorCommand.scrollToLine(0).argumentJSON, "1")
        XCTAssertEqual(
            WebEditorCommand.scrollToLine(3).javaScript,
            "window.scribeCommand && window.scribeCommand(\"scrollToLine\", 3);"
        )
    }

    func testFindPrefilledEscapesQuery() {
        let command = WebEditorCommand.findPrefilled("say \"hi\"\n</script>")
        XCTAssertEqual(command.name, "find")
        XCTAssertTrue(command.argumentJSON.hasPrefix("\""))
        XCTAssertTrue(command.argumentJSON.hasSuffix("\""))
        XCTAssertFalse(command.argumentJSON.contains("\n"))
        XCTAssertTrue(command.argumentJSON.contains("\\\"hi\\\""))
    }

    func testStringLiteralRoundTripsThroughJSON() throws {
        let original = "line1\nline2 \u{2028} \"quoted\" \\ back"
        let literal = WebEditorJS.stringLiteral(original)
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        XCTAssertEqual(decoded, [original])
    }

    // MARK: - Outline

    func testParseOutlineReadsValidEntries() {
        let raw: [Any] = [
            ["level": 1, "text": "Title", "line": 1] as [String: Any],
            ["level": 2.0, "text": "  Section  ", "line": 5.0] as [String: Any],
            ["level": 7, "text": "Bad level", "line": 9] as [String: Any],
            ["level": 3, "text": "Bad line", "line": 0] as [String: Any],
            ["text": "Missing level", "line": 3] as [String: Any],
            "not a dict",
        ]
        let headings = EditorOutlineHeading.parseList(raw)
        XCTAssertEqual(headings, [
            EditorOutlineHeading(level: 1, text: "Title", line: 1),
            EditorOutlineHeading(level: 2, text: "Section", line: 5),
        ])
        XCTAssertEqual(headings.map(\.id), [1, 5])
    }

    func testParseOutlineHandlesNonArrays() {
        XCTAssertEqual(EditorOutlineHeading.parseList(nil), [])
        XCTAssertEqual(EditorOutlineHeading.parseList("nope"), [])
        XCTAssertEqual(EditorOutlineHeading.parseList([Any]()), [])
    }

    // MARK: - Completion data

    func testCompletionDataLiteralIsValidJSON() throws {
        let data = EditorCompletionData(titles: ["Alpha \"A\"", "Beta"], tags: ["work"])
        let object = try JSONSerialization.jsonObject(with: Data(data.javaScriptLiteral.utf8)) as? [String: [String]]
        XCTAssertEqual(object?["titles"], ["Alpha \"A\"", "Beta"])
        XCTAssertEqual(object?["tags"], ["work"])
    }
}

@MainActor
final class WebEditorModelTests: XCTestCase {

    func testPerformWithoutEditorReturnsFalse() {
        let model = WebEditorModel()
        XCTAssertFalse(model.perform(.find))
        XCTAssertTrue(model.outline.isEmpty)
    }

    func testCommandCenterWithoutEditorsHasNoTarget() {
        let center = WebEditorCommandCenter()
        XCTAssertFalse(center.send(.findNext))
        XCTAssertFalse(center.send(named: "findPrevious"))
    }
}

final class WebEditorTextFinderMappingTests: XCTestCase {

    func testStandardFindMenuTagsMapToEditorCommands() {
        XCTAssertEqual(WebEditorCommand.forTextFinderAction(tag: 1), .find)
        XCTAssertEqual(WebEditorCommand.forTextFinderAction(tag: 2), .findNext)
        XCTAssertEqual(WebEditorCommand.forTextFinderAction(tag: 3), .findPrevious)
        XCTAssertEqual(WebEditorCommand.forTextFinderAction(tag: 12), .replace)
        XCTAssertNil(WebEditorCommand.forTextFinderAction(tag: 5))
        XCTAssertNil(WebEditorCommand.forTextFinderAction(tag: 0))
    }
}
