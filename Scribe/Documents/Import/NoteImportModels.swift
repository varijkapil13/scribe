// Scribe/Documents/Import/NoteImportModels.swift
//
// The importer pipeline: a source reader (Evernote, Notion, Markdown folder,
// Apple Notes, PDF/image) turns its input into `ImportedNoteDraft`s; the
// `NoteImportWriter` then saves attachments, de-duplicates titles, creates
// notebooks and writes the notes into the vault. Drafts reference their
// attachments through placeholder destinations the writer swaps for the
// real `attachments/<noteId>/<file>` paths.

import Foundation

/// Bytes or a file to copy into a note's attachments folder.
struct ImportedAttachmentSource: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case data(Data)
        case file(URL)
    }

    var content: Content
    var filename: String
    var mimeType: String?
}

/// A note about to be imported.
struct ImportedNoteDraft: Equatable, Sendable {
    var title: String
    /// Markdown; may contain attachment placeholders (see
    /// `ImportAttachmentCollector`).
    var body: String
    var tags: [String] = []
    var createdAt: Date?
    var updatedAt: Date?
    /// Notebook names from the outermost in (`["Work", "Clients"]`); empty
    /// for the Inbox.
    var notebookPath: [String] = []
    /// Placeholder → attachment.
    var attachments: [String: ImportedAttachmentSource] = [:]
    /// Extra frontmatter to keep (e.g. Obsidian `aliases:`).
    var extra: [FrontmatterEntry] = []
    /// Where the draft came from (for the summary), e.g. a file name.
    var sourceName: String = ""
}

/// Hands out unique placeholder destinations for one draft's attachments.
struct ImportAttachmentCollector {
    private(set) var attachments: [String: ImportedAttachmentSource] = [:]
    private var counter = 0
    /// Same source registered twice (an image used twice) → same placeholder.
    private var bySourceKey: [String: String] = [:]

    static let placeholderPrefix = "scribe-import-attachment-"

    init() {}

    /// Registers `source` and returns the placeholder to put in Markdown.
    mutating func register(_ source: ImportedAttachmentSource, dedupeKey: String? = nil) -> String {
        if let dedupeKey, let existing = bySourceKey[dedupeKey] { return existing }
        counter += 1
        let placeholder = "\(Self.placeholderPrefix)\(counter)-\(UUID().uuidString.prefix(8).lowercased())"
        attachments[placeholder] = source
        if let dedupeKey { bySourceKey[dedupeKey] = placeholder }
        return placeholder
    }
}

/// What happened to one source item.
struct NoteImportItemResult: Equatable, Sendable, Identifiable {
    enum Outcome: Equatable, Sendable {
        case imported(noteId: String, title: String, renamed: Bool)
        case skipped(reason: String)
        case failed(reason: String)
    }

    let id = UUID()
    var sourceName: String
    var outcome: Outcome

    static func == (lhs: NoteImportItemResult, rhs: NoteImportItemResult) -> Bool {
        lhs.sourceName == rhs.sourceName && lhs.outcome == rhs.outcome
    }
}

/// The summary shown when an import finishes.
struct NoteImportSummary: Equatable, Sendable {
    var sourceLabel: String
    var items: [NoteImportItemResult] = []
    var attachmentsSaved = 0
    var attachmentsFailed = 0
    var notebooksCreated = 0
    /// Problems not tied to one note (e.g. an unreadable file).
    var warnings: [String] = []

    var importedCount: Int {
        items.filter { if case .imported = $0.outcome { return true } else { return false } }.count
    }

    var renamedCount: Int {
        items.filter { if case .imported(_, _, true) = $0.outcome { return true } else { return false } }.count
    }

    var failedCount: Int {
        items.filter { if case .failed = $0.outcome { return true } else { return false } }.count
    }

    var skippedCount: Int {
        items.filter { if case .skipped = $0.outcome { return true } else { return false } }.count
    }

    /// The first imported note, to open when the user clicks "Show".
    var firstImportedNoteId: String? {
        for item in items {
            if case .imported(let noteId, _, _) = item.outcome { return noteId }
        }
        return nil
    }

    /// One-line description, e.g. "Imported 12 notes (2 renamed), 1 failed."
    var headline: String {
        var parts = ["Imported \(importedCount) note\(importedCount == 1 ? "" : "s")"]
        if renamedCount > 0 { parts[0] += " (\(renamedCount) renamed to keep titles unique)" }
        var tail: [String] = []
        if failedCount > 0 { tail.append("\(failedCount) failed") }
        if skippedCount > 0 { tail.append("\(skippedCount) skipped") }
        if attachmentsFailed > 0 {
            tail.append("\(attachmentsFailed) attachment\(attachmentsFailed == 1 ? "" : "s") couldn't be saved")
        }
        return tail.isEmpty ? parts[0] + "." : parts[0] + ", " + tail.joined(separator: ", ") + "."
    }
}

/// Progress reported while importing (sent to the main actor).
struct NoteImportProgress: Equatable, Sendable {
    var phase: String
    var completed: Int
    var total: Int

    var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }
}
