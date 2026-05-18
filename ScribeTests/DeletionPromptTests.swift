// ScribeTests/DeletionPromptTests.swift
import XCTest
@testable import Scribe

/// Pure copy-builder tests for the delete-note confirmation dialog. The
/// review flagged silent data-loss when a user deletes an auto-created
/// "Meeting on …" note that owns recordings — these assertions enforce
/// that the dialog surfaces the cascade in plain language before the
/// user can commit.
@MainActor
final class DeletionPromptTests: XCTestCase {

    func testTitleQuotesTheNoteName() {
        let request = DeleteNoteRequest(noteId: "n1", noteTitle: "Q3 Planning", sessionCount: 0)
        XCTAssertEqual(DeletionPrompt.title(for: request),
                       "Delete \u{201C}Q3 Planning\u{201D}?")
    }

    func testTitleFallsBackForUntitledNote() {
        let request = DeleteNoteRequest(noteId: "n1", noteTitle: "", sessionCount: 0)
        XCTAssertEqual(DeletionPrompt.title(for: request),
                       "Delete this note?")
    }

    func testTitleHandlesNilRequest() {
        XCTAssertEqual(DeletionPrompt.title(for: nil),
                       "Delete this note?")
    }

    func testMessageOmitsRecordingWarningWhenNoSessions() {
        let request = DeleteNoteRequest(noteId: "n1", noteTitle: "Standup", sessionCount: 0)
        let msg = DeletionPrompt.message(for: request)
        XCTAssertFalse(msg.contains("recording"),
                       "No recordings → no scary cascade warning. Got: \(msg)")
        XCTAssertTrue(msg.contains("permanently"))
    }

    func testMessageWarnsAboutSingleLinkedRecording() {
        let request = DeleteNoteRequest(noteId: "n1", noteTitle: "Sync", sessionCount: 1)
        let msg = DeletionPrompt.message(for: request)
        XCTAssertTrue(msg.contains("1 linked recording"),
                      "Expected exact 'X linked recording' phrasing. Got: \(msg)")
        // Singular form — no trailing s.
        XCTAssertFalse(msg.contains("1 linked recordings"))
        XCTAssertTrue(msg.contains("summary"), "Cascade list must mention summary")
        XCTAssertTrue(msg.contains("action items"), "Cascade list must mention action items")
    }

    func testMessageWarnsAboutMultipleLinkedRecordings() {
        let request = DeleteNoteRequest(noteId: "n1", noteTitle: "Project", sessionCount: 3)
        let msg = DeletionPrompt.message(for: request)
        XCTAssertTrue(msg.contains("3 linked recordings"),
                      "Plural form expected. Got: \(msg)")
    }

    func testMessageMentionsTaskSurvivalPolicy() {
        // tasks.sourceSessionId is ON DELETE SET NULL — the dialog should
        // tell the user converted tasks survive (just lose the source link)
        // so they don't think their TODO list will vanish.
        let request = DeleteNoteRequest(noteId: "n1", noteTitle: "X", sessionCount: 2)
        let msg = DeletionPrompt.message(for: request)
        XCTAssertTrue(msg.lowercased().contains("tasks"),
                      "Message should reassure about converted tasks. Got: \(msg)")
    }
}
