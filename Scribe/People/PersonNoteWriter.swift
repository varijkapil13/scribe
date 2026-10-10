// Scribe/People/PersonNoteWriter.swift
import Foundation

// MARK: - Pure content

/// Builds the auto-generated part of a person note and splices it into an
/// existing body without touching anything the user wrote outside it.
///
/// The generated part lives between two HTML-comment markers (invisible in
/// rendered markdown, Obsidian-compatible). Refreshing replaces only what
/// is between them; everything before and after is preserved verbatim.
enum PersonNoteContent {

    static let startMarker = "<!-- scribe:person:auto:start -->"
    static let endMarker = "<!-- scribe:person:auto:end -->"

    /// The delimited block (markers included) for `person`.
    nonisolated static func autoBlock(for person: Person) -> String {
        var lines: [String] = [startMarker, "## Meetings", ""]
        if person.meetings.isEmpty {
            lines.append("_No meetings yet._")
        } else {
            for meeting in person.meetings {
                let date = MeetingRetrieval.dayString(meeting.date)
                let link = meeting.hasNote ? "[[\(meeting.linkTitle)]]" : meeting.linkTitle
                lines.append("- \(link) · \(date)")
            }
        }
        lines.append("")
        lines.append("## Open tasks")
        lines.append("")
        if person.openTasks.isEmpty {
            lines.append("_No open tasks._")
        } else {
            for task in person.openTasks {
                if let due = task.dueAt {
                    lines.append("- \(task.title) · due \(MeetingRetrieval.dayString(due))")
                } else {
                    lines.append("- \(task.title)")
                }
            }
        }
        lines.append("")
        lines.append("_Updated by Scribe. Write your own notes outside this block._")
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Body for a brand-new person note: the block plus a section for the
    /// user's own notes.
    nonisolated static func initialBody(block: String) -> String {
        block + "\n\n## Notes\n\n"
    }

    /// Replaces the existing delimited block in `body` with `block`, or
    /// appends `block` when there is none. A start marker without a matching
    /// end marker (e.g. the user deleted half of it) is removed and a fresh
    /// block is appended, so user text after it is never swallowed.
    nonisolated static func upsert(block: String, into body: String) -> String {
        if let start = body.range(of: startMarker) {
            if let end = body.range(of: endMarker, range: start.upperBound..<body.endIndex) {
                var out = body
                out.replaceSubrange(start.lowerBound..<end.upperBound, with: block)
                return out
            }
            // Dangling start marker — drop it, then append.
            var cleaned = body
            cleaned.removeSubrange(start)
            return append(block: block, to: cleaned)
        }
        return append(block: block, to: body)
    }

    private static func append(block: String, to body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return block + "\n" }
        var out = body
        while out.hasSuffix("\n") { out.removeLast() }
        return out + "\n\n" + block + "\n"
    }
}

// MARK: - Note service

/// Creates or refreshes a person's note in the vault.
///
/// Notes are files at the vault root named after their title (the repo's
/// `NoteFileStore` convention); grouping is via the DB-level "People"
/// notebook, which the sidebar's notebook tree shows as a folder. Person
/// notes are also tagged `#person`.
struct PersonNoteService {

    static let notebookName = "People"
    static let personTag = "person"

    let noteStore: NoteStore

    init(noteStore: NoteStore = .shared) {
        self.noteStore = noteStore
    }

    /// The existing person note for `person`, if any: a note titled with
    /// the person's name that is in the People notebook or tagged `#person`.
    func existingNote(for person: Person) throws -> Note? {
        guard let id = try existingNoteId(for: person) else { return nil }
        return try noteStore.fetchNote(id: id)
    }

    /// Id of the existing person note — database-only (no file read), so it
    /// is cheap enough to call while rendering a list.
    func existingNoteId(for person: Person) throws -> String? {
        guard let match = try noteStore.resolveTitle(person.name) else { return nil }
        let notebookId = try peopleNotebookId(createIfMissing: false)
        let tags = try noteStore.tags(for: match.id)
        let isPersonNote = (notebookId != nil && match.notebookId == notebookId)
            || tags.contains(Self.personTag)
        return isPersonNote ? match.id : nil
    }

    /// Creates the person note, or refreshes the auto block of an existing
    /// one. Returns the note.
    @discardableResult
    func createOrRefresh(_ person: Person) throws -> Note {
        let block = PersonNoteContent.autoBlock(for: person)

        if var existing = try existingNote(for: person) {
            // Never write into a locked note's ciphertext.
            guard !LockedNoteEnvelope.isLocked(existing.body) else { return existing }
            let updated = PersonNoteContent.upsert(block: block, into: existing.body)
            guard updated != existing.body else { return existing }
            existing.body = updated
            var tags = try noteStore.tags(for: existing.id)
            if !tags.contains(Self.personTag) { tags.append(Self.personTag) }
            try noteStore.updateNote(existing, tags: tags)
            return existing
        }

        let notebookId = try peopleNotebookId(createIfMissing: true)
        let created = try noteStore.createNote(
            title: person.name,
            body: PersonNoteContent.initialBody(block: block),
            tags: [Self.personTag],
            notebookId: notebookId
        )
        // `createNote` doesn't index wiki-links; an update does, so the
        // person note shows up as a backlink on each meeting note.
        try noteStore.updateNote(created, tags: [Self.personTag])
        return created
    }

    /// Top-level "People" notebook id.
    private func peopleNotebookId(createIfMissing: Bool) throws -> String? {
        let notebooks = try noteStore.fetchAllNotebooks()
        if let existing = notebooks.first(where: {
            $0.parentId == nil && $0.name.caseInsensitiveCompare(Self.notebookName) == .orderedSame
        }) {
            return existing.id
        }
        guard createIfMissing else { return nil }
        return try noteStore.createNotebook(name: Self.notebookName).id
    }
}
