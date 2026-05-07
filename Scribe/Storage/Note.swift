// Scribe/Storage/Note.swift
import Foundation
import GRDB

struct Note: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isDailyNote: Bool
    var dailyDate: String?  // "YYYY-MM-DD", only set when isDailyNote == true

    init(
        id: String = UUID().uuidString,
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDailyNote: Bool = false,
        dailyDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDailyNote = isDailyNote
        self.dailyDate = dailyDate
    }
}

extension Note: FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"
}

struct NoteLinkRow: Codable, Equatable, Hashable {
    var sourceNoteId: String
    var targetNoteId: String
    var anchorText: String
}

extension NoteLinkRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_links"
}

struct NoteTagRow: Codable, Equatable, Hashable {
    var noteId: String
    var tag: String
}

extension NoteTagRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_tags"
}
