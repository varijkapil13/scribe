// ScribeTests/EditorCaptureNamingTests.swift
import XCTest
@testable import Scribe

final class EditorCaptureNamingTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC") ?? .current
    // 2026-10-10 14:30:05 UTC
    private let date = Date(timeIntervalSince1970: 1_791_642_605)

    func testTimestampedNames() {
        XCTAssertEqual(EditorCaptureNaming.filename(kind: .photo, date: date, ext: "PNG", timeZone: utc),
                       "photo-20261010-143005.png")
        XCTAssertEqual(EditorCaptureNaming.filename(kind: .camera, date: date, ext: ".jpeg", timeZone: utc),
                       "camera-20261010-143005.jpeg")
        XCTAssertEqual(EditorCaptureNaming.filename(kind: .scan, date: date, ext: "", timeZone: utc),
                       "scan-20261010-143005.jpg")
    }

    func testPagesOnlyForMultiPageScans() {
        XCTAssertEqual(EditorCaptureNaming.filename(kind: .scan, date: date, ext: "jpg", page: 2, pageCount: 3, timeZone: utc),
                       "scan-20261010-143005-page2.jpg")
        XCTAssertEqual(EditorCaptureNaming.filename(kind: .scan, date: date, ext: "jpg", page: 1, pageCount: 1, timeZone: utc),
                       "scan-20261010-143005.jpg")
    }

    func testNamesSurviveAttachmentSanitizing() {
        let name = EditorCaptureNaming.filename(kind: .scan, date: date, ext: "jpg", page: 2, pageCount: 2, timeZone: utc)
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename(name, mimeType: "image/jpeg"), name)
        XCTAssertTrue(EditorAttachmentFiles.isImage(filename: name, mimeType: nil))
    }

    func testImageFormatSniffing() {
        XCTAssertEqual(EditorCaptureNaming.imageFormat(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])).ext, "png")
        XCTAssertEqual(EditorCaptureNaming.imageFormat(of: Data([0xFF, 0xD8, 0xFF, 0xE0])).mimeType, "image/jpeg")
        XCTAssertEqual(EditorCaptureNaming.imageFormat(of: Data("GIF89a".utf8)).ext, "gif")
        XCTAssertEqual(EditorCaptureNaming.imageFormat(of: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8)).ext, "webp")
        XCTAssertEqual(EditorCaptureNaming.imageFormat(of: Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))).ext, "heic")
        XCTAssertEqual(EditorCaptureNaming.imageFormat(of: Data([1, 2, 3])).ext, "jpg")
    }
}
