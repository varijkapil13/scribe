import XCTest
@testable import Scribe

/// The menu → CodeMirror bridge: command names must match the JS
/// dispatcher (editor-web/src/commands.js).
final class EditorCommandTests: XCTestCase {

    func testCommandNamesMatchTheJavaScriptDispatcher() {
        let expected: [(EditorCommand, String)] = [
            (.bold, "bold"), (.italic, "italic"), (.strikethrough, "strikethrough"),
            (.inlineCode, "code"), (.link, "link"), (.heading(2), "heading"),
            (.bulletedList, "bulletList"), (.numberedList, "orderedList"),
            (.checklist, "checklist"), (.quote, "blockquote"),
            (.find, "find"), (.findAndReplace, "replace"),
            (.findNext, "findNext"), (.findPrevious, "findPrevious"),
        ]
        for (command, name) in expected {
            XCTAssertEqual(command.jsName, name)
        }
    }

    func testHeadingArgumentIsClamped() {
        XCTAssertEqual(EditorCommand.heading(0).argument, 0)
        XCTAssertEqual(EditorCommand.heading(3).argument, 3)
        XCTAssertEqual(EditorCommand.heading(9).argument, 6)
        XCTAssertEqual(EditorCommand.heading(-1).argument, 0)
        XCTAssertNil(EditorCommand.bold.argument)
    }

    func testJavaScriptIsGuardedAndPassesNameAndArgument() {
        let bold = EditorCommand.bold.javaScript
        XCTAssertTrue(bold.contains("typeof window.scribeCommand==='function'"))
        XCTAssertTrue(bold.contains("window.scribeCommand('bold',null)"))

        let h1 = EditorCommand.heading(1).javaScript
        XCTAssertTrue(h1.contains("window.scribeCommand('heading',1)"))

        XCTAssertTrue(EditorCommand.findPrevious.javaScript.contains("'findPrevious'"))
    }
}
