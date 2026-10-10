// Scribe/Storage/NoteStore+PowerNotes.swift
import Foundation
import GRDB

// Link resolution for heading / block / alias links, version snapshots, and
// the FTS lookup behind "unlinked mentions".
extension NoteStore {

    // MARK: - Link resolution

    /// The note a `[[wiki link]]` anchor points at: the text before `|` as a
    /// title first, then the title without its `#Heading` / `#^block`
    /// fragment (case-insensitive, like every title lookup).
    static func resolveLinkTarget(_ database: Database, anchor: String) throws -> Note? {
        for candidate in WikiLinkTarget.lookupCandidates(forAnchor: anchor) {
            if let note = try Note
                .filter(sql: "LOWER(title) = LOWER(?)", arguments: [candidate])
                .fetchOne(database) {
                return note
            }
        }
        return nil
    }

    /// `resolveTitle` for a full link anchor (`Note#Heading|alias`).
    func resolveLinkTarget(anchor: String) throws -> Note? {
        try dbManager.database.read { database in
            try Self.resolveLinkTarget(database, anchor: anchor)
        }
    }

    // MARK: - Version history

    /// Snapshots the note's current on-disk content before `note` replaces
    /// it. Best-effort: failures are logged, never thrown.
    func recordVersionBeforeSave(of note: Note, reason: NoteVersionReason) {
        guard let versionStore, let fileStore,
              let entry = try? fileStore.locate(id: note.id) else { return }
        do {
            try versionStore.recordSnapshotIfNeeded(
                noteId: note.id,
                title: entry.file.frontmatter.title,
                previousBody: entry.file.body,
                newBody: note.body,
                reason: reason
            )
        } catch {
            Log.storage.error("NoteStore: version snapshot failed for \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stores `body` as a version of the note right now (bypassing the
    /// throttle; an exact duplicate of the newest version is skipped). Used
    /// before the editor adopts an external change. Best-effort.
    func snapshotVersion(noteId: String, title: String, body: String, reason: NoteVersionReason) {
        guard let versionStore else { return }
        do {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try versionStore.snapshot(noteId: noteId, title: title, body: body, reason: reason)
        } catch {
            Log.storage.error("NoteStore: version snapshot failed for \(noteId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Unlinked mentions

    /// FTS5 MATCH expression for any of `terms` as a phrase: each term is
    /// split into tokens the way the unicode61 tokenizer does and quoted.
    /// Empty when no term has a token.
    nonisolated static func mentionMatchExpression(terms: [String]) -> String {
        let phrases: [String] = terms.compactMap { term in
            let tokens = term
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return nil }
            return "\"" + tokens.joined(separator: " ") + "\""
        }
        return phrases.joined(separator: " OR ")
    }

    /// Ids of notes whose indexed text contains any of `terms` as a phrase,
    /// excluding `noteId` itself. Candidates only — callers confirm with
    /// `UnlinkedMentionMatcher` against the real body.
    func mentionCandidateIds(terms: [String], excludingNoteId noteId: String, limit: Int = 200) throws -> [String] {
        let expression = Self.mentionMatchExpression(terms: terms)
        guard !expression.isEmpty else { return [] }
        return try dbManager.database.read { database in
            try String.fetchAll(database, sql: """
                SELECT notes.id FROM notes
                JOIN notes_fts ON notes.id = notes_fts.noteId
                WHERE notes_fts MATCH ? AND notes.id != ?
                ORDER BY notes.updatedAt DESC
                LIMIT ?
                """, arguments: [expression, noteId, limit])
        }
    }

    /// Notes (with their bodies) that mention `title` / `aliases` without
    /// linking, each with its mentions. Excludes `noteId`.
    func unlinkedMentions(ofNoteId noteId: String, title: String, aliases: [String])
        throws -> [(note: Note, mentions: [UnlinkedMention])] {
        let terms = UnlinkedMentionMatcher.terms(title: title, aliases: aliases)
        guard !terms.isEmpty else { return [] }
        var out: [(note: Note, mentions: [UnlinkedMention])] = []
        for id in try mentionCandidateIds(terms: terms, excludingNoteId: noteId) {
            guard let note = try fetchNote(id: id) else { continue }
            let mentions = UnlinkedMentionMatcher.mentions(of: terms, in: note.body)
            if !mentions.isEmpty { out.append((note: note, mentions: mentions)) }
        }
        return out
    }

    /// Aliases from the note's frontmatter `aliases:` key.
    func aliases(forNoteId noteId: String) -> [String] {
        UnlinkedMentionMatcher.parseAliases(diskEntry(forNoteId: noteId)?.file.frontmatter.extraValue(forKey: "aliases"))
    }
}
