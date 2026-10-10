import XCTest
@testable import Scribe

/// Print / Export as PDF: the HTML a note is rendered to.
final class NotePrintHTMLTests: XCTestCase {

    func testEscapesHTMLSpecialCharacters() {
        XCTAssertEqual(NotePrintHTML.escape(#"<a href="x">Tom & 'Jerry'</a>"#),
                       "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
        XCTAssertEqual(NotePrintHTML.escape("plain"), "plain")
    }

    func testMarkdownBecomesHTML() {
        let html = NotePrintHTML.bodyHTML(fromMarkdown: "# Heading\n\nSome **bold** and *italic* text.\n\n- one\n- two\n")
        XCTAssertTrue(html.contains("<h1>"), html)
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<em>italic</em>"), html)
        XCTAssertTrue(html.contains("<li>"), html)
    }

    func testDocumentWrapsBodyWithEscapedTitleAndLockedDownCSP() {
        let page = NotePrintHTML.document(title: "Q3 <draft>", bodyHTML: "<p>Hi</p>")
        XCTAssertTrue(page.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(page.contains("<title>Q3 &lt;draft&gt;</title>"))
        XCTAssertTrue(page.contains("<p>Hi</p>"))
        XCTAssertTrue(page.contains("Content-Security-Policy"))
        XCTAssertTrue(page.contains("default-src 'none'"), "Scripts and remote loads stay blocked")
    }

    func testDocumentForNoteUsesTheMarkdownExporter() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: dbm)
        let note = Note(title: "Weekly sync", body: "Agenda with **owners**")
        let page = NotePrintHTML.document(for: note, transcriptStore: transcripts)
        XCTAssertTrue(page.contains("<title>Weekly sync</title>"))
        XCTAssertTrue(page.contains("Weekly sync</h1>"), "Exporter's title heading is rendered")
        XCTAssertTrue(page.contains("<strong>owners</strong>"))
    }
}
