// ScribeTests/EvernoteENEXParserTests.swift
import XCTest
@testable import Scribe

final class EvernoteENEXParserTests: XCTestCase {

    /// Bytes of a 1×1 PNG-like payload (content doesn't matter, only the hash).
    private let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    private let pdfBytes = Data("%PDF-1.4 tiny".utf8)

    private func enex() -> String {
        let imageHash = EvernoteENEXParser.md5Hex(imageBytes)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
        <en-export export-date="20240301T120000Z" application="Evernote" version="10.0">
          <note>
            <title>Kitchen &amp; Bath</title>
            <created>20240131T094500Z</created>
            <updated>20240201T101500Z</updated>
            <tag>home</tag>
            <tag>renovation</tag>
            <note-attributes><author>Me</author></note-attributes>
            <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note><div><b>Tiles</b> chosen</div><div><en-todo checked="true"/>Order grout</div><div><en-media hash="\(imageHash)" type="image/png"/></div></en-note>]]></content>
            <resource>
              <data encoding="base64">\(imageBytes.base64EncodedString())</data>
              <mime>image/png</mime>
              <resource-attributes><file-name>tiles.png</file-name></resource-attributes>
            </resource>
            <resource>
              <data encoding="base64">
        \(pdfBytes.base64EncodedString())
              </data>
              <mime>application/pdf</mime>
              <resource-attributes><file-name>quote.pdf</file-name></resource-attributes>
            </resource>
          </note>
          <note>
            <title></title>
            <content><![CDATA[<en-note>Second</en-note>]]></content>
          </note>
        </en-export>
        """
    }

    func testParsesNotesTagsDatesAndResources() throws {
        let notes = try EvernoteENEXParser.parse(data: Data(enex().utf8))
        XCTAssertEqual(notes.count, 2)
        let first = notes[0]
        XCTAssertEqual(first.title, "Kitchen & Bath")
        XCTAssertEqual(first.tags, ["home", "renovation"])
        XCTAssertEqual(first.created, Date(timeIntervalSince1970: 1_706_694_300))
        XCTAssertEqual(first.updated, Date(timeIntervalSince1970: 1_706_782_500))
        XCTAssertEqual(first.resources.count, 2)
        XCTAssertEqual(first.resources[0].data, imageBytes)
        XCTAssertEqual(first.resources[0].fileName, "tiles.png")
        XCTAssertEqual(first.resources[0].mimeType, "image/png")
        XCTAssertEqual(first.resources[0].hash, EvernoteENEXParser.md5Hex(imageBytes))
        // Base64 spread over lines with whitespace still decodes.
        XCTAssertEqual(first.resources[1].data, pdfBytes)
        XCTAssertTrue(first.contentENML.contains("<en-note>"))
        XCTAssertEqual(notes[1].title, "")
        XCTAssertTrue(notes[1].resources.isEmpty)
    }

    func testMarkdownEmbedsReferencedMedia() throws {
        let note = try XCTUnwrap(try EvernoteENEXParser.parse(data: Data(enex().utf8)).first)
        let markdown = EvernoteENEXParser.markdown(for: note) { resource in
            "attachments/n/\(resource.fileName ?? "x")"
        }
        XCTAssertEqual(markdown, "**Tiles** chosen\n- [x] Order grout\n![tiles.png](attachments/n/tiles.png)")
    }

    func testDraftKeepsUnreferencedResourcesAndUsesPlaceholders() throws {
        let note = try XCTUnwrap(try EvernoteENEXParser.parse(data: Data(enex().utf8)).first)
        let draft = NoteImportSources.evernoteDraft(note, notebook: "House", sourceName: "House.enex")
        XCTAssertEqual(draft.title, "Kitchen & Bath")
        XCTAssertEqual(draft.notebookPath, ["House"])
        XCTAssertEqual(draft.tags, ["home", "renovation"])
        XCTAssertEqual(draft.createdAt, note.created)
        XCTAssertEqual(draft.attachments.count, 2)
        // Every placeholder appears in the body exactly once.
        for placeholder in draft.attachments.keys {
            XCTAssertEqual(draft.body.components(separatedBy: placeholder).count, 2, placeholder)
            XCTAssertTrue(placeholder.hasPrefix(ImportAttachmentCollector.placeholderPrefix))
        }
        // The PDF wasn't referenced by the ENML: it is listed at the end.
        XCTAssertTrue(draft.body.contains("- [quote.pdf]("))
        let pdf = try XCTUnwrap(draft.attachments.values.first { $0.filename == "quote.pdf" })
        XCTAssertEqual(pdf.content, .data(pdfBytes))
        XCTAssertEqual(pdf.mimeType, "application/pdf")
    }

    func testUntitledNoteGetsAFallbackTitle() throws {
        let notes = try EvernoteENEXParser.parse(data: Data(enex().utf8))
        let draft = NoteImportSources.evernoteDraft(notes[1], notebook: "", sourceName: "x.enex")
        XCTAssertEqual(draft.title, "Untitled")
        XCTAssertEqual(draft.body, "Second")
        XCTAssertEqual(draft.notebookPath, [])
    }

    func testInvalidXMLThrows() {
        XCTAssertThrowsError(try EvernoteENEXParser.parse(data: Data("not xml at all <".utf8)))
    }

    func testDateParsingAndMD5() {
        XCTAssertEqual(EvernoteENEXParser.parseDate("20240131T094500Z"), Date(timeIntervalSince1970: 1_706_694_300))
        XCTAssertNil(EvernoteENEXParser.parseDate(""))
        XCTAssertNil(EvernoteENEXParser.parseDate("yesterday"))
        XCTAssertEqual(EvernoteENEXParser.md5Hex(Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testCollectorDedupesBySourceKey() {
        var collector = ImportAttachmentCollector()
        let source = ImportedAttachmentSource(content: .data(Data([1])), filename: "a.png", mimeType: nil)
        let first = collector.register(source, dedupeKey: "k")
        let again = collector.register(source, dedupeKey: "k")
        let other = collector.register(source)
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(collector.attachments.count, 2)
    }
}
