import XCTest
@testable import Scribe

/// Block splitter behind the Quick Look Markdown preview extension.
final class ScribeMarkdownPreviewParserTests: XCTestCase {

    func testFrontmatterIsStrippedAndTitleRead() {
        let text = """
        ---
        id: abc
        title: "Weekly sync"
        tags: [work]
        ---
        Body line
        """
        let (fields, body) = ScribeMarkdownPreviewParser.splitFrontmatter(text)
        XCTAssertEqual(fields["title"], "Weekly sync")
        XCTAssertEqual(fields["id"], "abc")
        XCTAssertEqual(body, "Body line")

        let document = ScribeMarkdownPreviewParser.parse(text)
        XCTAssertEqual(document.title, "Weekly sync")
        XCTAssertEqual(document.blocks, [.paragraph("Body line")])
    }

    func testUnclosedFrontmatterIsKeptAsText() {
        let (fields, body) = ScribeMarkdownPreviewParser.splitFrontmatter("---\ntitle: x\nno end")
        XCTAssertTrue(fields.isEmpty)
        XCTAssertEqual(body, "---\ntitle: x\nno end")
    }

    func testHeadingsParagraphsAndRules() {
        let blocks = ScribeMarkdownPreviewParser.blocks(from: """
        # Title
        Some **bold**
        text continues

        ## Section ##
        #hashtag is not a heading
        ***
        Setext
        ======
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text continues"),
            .heading(level: 2, text: "Section"),
            .paragraph("#hashtag is not a heading"),
            .rule,
            .heading(level: 1, text: "Setext"),
        ])
    }

    func testListsAndTasks() {
        let blocks = ScribeMarkdownPreviewParser.blocks(from: """
        - one
          * nested
        1. first
        2) second
        - [ ] open task
        - [x] done task
        -not a list
        """)
        XCTAssertEqual(blocks, [
            .bullet(indent: 0, text: "one"),
            .bullet(indent: 1, text: "nested"),
            .numbered(indent: 0, marker: "1.", text: "first"),
            .numbered(indent: 0, marker: "2)", text: "second"),
            .task(indent: 0, isChecked: false, text: "open task"),
            .task(indent: 0, isChecked: true, text: "done task"),
            .paragraph("-not a list"),
        ])
    }

    func testQuotesAndCodeFences() {
        let blocks = ScribeMarkdownPreviewParser.blocks(from: """
        > quoted
        > more
        ```swift
        let x = 1
        # not a heading

        ```
        ~~~
        unclosed
        """)
        XCTAssertEqual(blocks, [
            .quote("quoted\nmore"),
            .code(language: "swift", text: "let x = 1\n# not a heading\n"),
            .code(language: nil, text: "unclosed"),
        ])
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(
            ScribeMarkdownPreviewParser.blocks(from: "# A\r\nb\r\n"),
            [.heading(level: 1, text: "A"), .paragraph("b")]
        )
    }
}
