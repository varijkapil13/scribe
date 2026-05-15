// ScribeTests/TestHelpers.swift
import Foundation
@testable import Scribe

enum TestHelpers {
    /// Creates a note via the given `NoteStore`, then creates a session via
    /// `TranscriptStore` bound to that note. Returns the session.
    /// Use this in tests that need a session without caring about the note.
    @discardableResult
    static func makeBoundSession(
        title: String,
        notes: NoteStore,
        transcripts: TranscriptStore,
        noteTitle: String = "Test note"
    ) throws -> Session {
        let note = try notes.createNote(title: noteTitle, body: "")
        return try transcripts.createSession(title: title, noteId: note.id)
    }
}
