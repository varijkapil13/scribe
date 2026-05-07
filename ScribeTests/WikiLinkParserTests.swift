// ScribeTests/WikiLinkParserTests.swift
import XCTest
@testable import Scribe

final class WikiLinkParserTests: XCTestCase {

    func testParsesSimpleLink() {
        let links = NoteStore.parseWikiLinks(from: "See [[Hello World]] for more.")
        XCTAssertEqual(links, ["Hello World"])
    }

    func testParsesMultipleLinks() {
        let links = NoteStore.parseWikiLinks(from: "[[A]] and [[B]] are linked.")
        XCTAssertEqual(Set(links), Set(["A", "B"]))
    }

    func testTrimsWhitespaceFromLinks() {
        let links = NoteStore.parseWikiLinks(from: "[[ My Note ]]")
        XCTAssertEqual(links, ["My Note"])
    }

    func testEmptyBodyReturnsEmpty() {
        XCTAssertEqual(NoteStore.parseWikiLinks(from: ""), [])
    }

    func testNoLinksInPlainText() {
        let links = NoteStore.parseWikiLinks(from: "Just plain text here.")
        XCTAssertTrue(links.isEmpty)
    }

    func testResolutionCaseInsensitive() throws {
        let db = try! DatabaseManager(path: ":memory:")
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "Swift Tips", body: "", tags: [])
        let resolved = try store.resolveTitle("swift tips")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.title, "Swift Tips")
    }

    func testResolutionNilForUnknown() throws {
        let db = try! DatabaseManager(path: ":memory:")
        let store = NoteStore(databaseManager: db)
        let resolved = try store.resolveTitle("nonexistent")
        XCTAssertNil(resolved)
    }
}
