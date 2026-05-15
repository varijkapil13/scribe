// ScribeTests/MarkdownListPrefixTests.swift
import XCTest
@testable import Scribe

final class MarkdownListPrefixTests: XCTestCase {

    func testListPrefixDetectsUncheckedChecklist() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- [ ] task"), "- [ ] ")
    }

    func testListPrefixDetectsCheckedChecklist() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- [x] done"), "- [x] ")
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- [X] done"), "- [X] ")
    }

    func testListPrefixDetectsPlainBullet() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- task"), "- ")
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "* task"), "* ")
    }

    func testListPrefixDetectsNumbered() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "1. task"), "1. ")
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "  42. nested"), "  42. ")
    }

    func testListPrefixNilForPlainText() {
        XCTAssertNil(MarkdownNSTextView.listPrefix(from: "no list here"))
    }

    func testNextListPrefixIncrementsNumbered() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "1. "), "2. ")
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "  42. "), "  43. ")
    }

    func testNextListPrefixRestartsCheckedToUnchecked() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- [x] "), "- [ ] ")
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- [X] "), "- [ ] ")
    }

    func testNextListPrefixPreservesUnchecked() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- [ ] "), "- [ ] ")
    }

    func testNextListPrefixPreservesPlainBullet() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- "), "- ")
    }
}
