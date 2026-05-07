// ScribeTests/DailyNoteTests.swift
import XCTest
@testable import Scribe

final class DailyNoteTests: XCTestCase {
    private var db: DatabaseManager!
    private var store: NoteStore!

    override func setUp() {
        db = try! DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: db)
    }

    func testDailyNoteTitleFormat() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 7))!
        let note = try store.dailyNote(for: date)
        XCTAssertTrue(note.title.contains("May 7, 2026"), "Got: \(note.title)")
        XCTAssertTrue(note.title.hasPrefix("Daily Note –"))
    }

    func testDailyNoteIsIdempotent() throws {
        let date = Date()
        let a = try store.dailyNote(for: date)
        let b = try store.dailyNote(for: date)
        XCTAssertEqual(a.id, b.id)
    }

    func testDifferentDatesGetDifferentNotes() throws {
        let cal = Calendar.current
        let today = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let a = try store.dailyNote(for: today)
        let b = try store.dailyNote(for: yesterday)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.dailyDate, b.dailyDate)
    }

    func testDailyNoteHasDailyFlag() throws {
        let note = try store.dailyNote(for: Date())
        XCTAssertTrue(note.isDailyNote)
        XCTAssertNotNil(note.dailyDate)
    }

    func testDailyNoteDateKeyFormat() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let note = try store.dailyNote(for: date)
        XCTAssertEqual(note.dailyDate, "2026-01-05")
    }
}
