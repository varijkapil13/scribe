import Foundation

/// Writes what a recording produced — the summary, action items, bookmarked
/// highlights and (optionally) the transcript — into its meeting note as
/// Scribe-owned blocks (`NoteScribeBlocks`).
///
/// Used by the iPhone / iPad recorder: sessions and segments live in each
/// device's local database, but the note is a markdown file in the (iCloud)
/// vault, so putting the results into the note is what carries them to the
/// Mac and the user's other devices. Blocks are replaced in place on a re-run
/// and never touch what the user typed around them.
///
/// The `summary` block uses the same kind / id (`summary:<sessionId>`) the
/// Mac's template summaries use, so a later re-summarize on the Mac replaces
/// it rather than adding a second one.
enum MeetingNoteRecap {

    /// Block kind for the transcript copy.
    nonisolated static let transcriptBlockKind = "transcript"

    // MARK: - Markdown

    /// Summary block content: the overview, then decisions, action items and
    /// open questions (each section only when non-empty).
    nonisolated static func summaryMarkdown(_ summary: MeetingSummary) -> String {
        var sections: [String] = []
        let overview = summary.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("## Summary\n\n" + (overview.isEmpty ? "_No summary._" : overview))

        let decisions = cleaned(summary.keyDecisions)
        if !decisions.isEmpty {
            sections.append("### Key decisions\n\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        let items = summary.actionItems.compactMap(actionItemLine)
        if !items.isEmpty {
            sections.append("### Action items\n\n" + items.joined(separator: "\n"))
        }
        let questions = cleaned(summary.followUpQuestions)
        if !questions.isEmpty {
            sections.append("### Open questions\n\n" + questions.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// `- [ ] Send the deck — Priya (due Friday)`; nil for an empty item.
    nonisolated static func actionItemLine(_ item: ActionItem) -> String? {
        let text = collapse(item.description)
        guard !text.isEmpty else { return nil }
        var line = "- [ ] \(text)"
        if let assignee = item.assignee.map(collapse), !assignee.isEmpty {
            line += " — \(assignee)"
        }
        if let deadline = item.deadline.map(collapse), !deadline.isEmpty {
            line += " (due \(deadline))"
        }
        return line
    }

    /// Transcript block content: one paragraph per segment,
    /// `**12:34 · Priya** What was said.`, or nil without segments.
    nonisolated static func transcriptMarkdown(
        segments: [Segment],
        speakerName: (Segment) -> String
    ) -> String? {
        let lines = segments
            .sorted { $0.startMs == $1.startMs ? ($0.id ?? 0) < ($1.id ?? 0) : $0.startMs < $1.startMs }
            .compactMap { segment -> String? in
                let text = collapse(segment.text)
                guard !text.isEmpty else { return nil }
                let stamp = SessionBookmarkFormatter.shortTimestamp(ms: segment.startMs)
                let speaker = speakerName(segment).trimmingCharacters(in: .whitespacesAndNewlines)
                let label = speaker.isEmpty ? stamp : "\(stamp) · \(speaker)"
                return "**\(label)** \(text)"
            }
        guard !lines.isEmpty else { return nil }
        return "## Transcript\n\n" + lines.joined(separator: "\n\n")
    }

    // MARK: - Applying

    /// The note body with each non-nil part upserted as its block, in a stable
    /// order (summary, highlights, transcript). A nil part leaves an existing
    /// block of that kind alone.
    nonisolated static func apply(
        to body: String,
        sessionId: String,
        summary: String?,
        highlights: String?,
        transcript: String?
    ) -> String {
        var out = body
        if let summary, !summary.isEmpty {
            out = NoteScribeBlocks.upsertSummary(body: out, sessionId: sessionId, content: summary)
        }
        if let highlights, !highlights.isEmpty {
            out = NoteScribeBlocks.upsert(body: out, kind: SessionBookmarkFormatter.noteBlockKind,
                                          id: sessionId, content: highlights)
        }
        if let transcript, !transcript.isEmpty {
            out = NoteScribeBlocks.upsert(body: out, kind: transcriptBlockKind, id: sessionId, content: transcript)
        }
        return out
    }

    /// The action items worth turning into tasks: non-empty, not converted
    /// already (`convertedIds` holds `ActionItem.id.uuidString`s), and no two
    /// with the same text.
    nonisolated static func itemsToConvert(_ items: [ActionItem], convertedIds: Set<String>) -> [ActionItem] {
        var seenText = Set<String>()
        return items.filter { item in
            let key = collapse(item.description).lowercased()
            guard !key.isEmpty, !convertedIds.contains(item.id.uuidString) else { return false }
            return seenText.insert(key).inserted
        }
    }

    // MARK: - Private

    private nonisolated static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private nonisolated static func cleaned(_ lines: [String]) -> [String] {
        lines.map(collapse).filter { !$0.isEmpty }
    }
}

/// Writes a ``MeetingNoteRecap`` into a stored note.
struct MeetingNoteRecapWriter {

    let noteStore: NoteStore

    /// Upserts the given parts into note `noteId`. Returns false when the note
    /// doesn't exist or nothing changed.
    @discardableResult
    func write(
        noteId: String,
        sessionId: String,
        summary: String?,
        highlights: String?,
        transcript: String?
    ) throws -> Bool {
        guard var note = try noteStore.fetchNote(id: noteId) else { return false }
        let updated = MeetingNoteRecap.apply(
            to: note.body,
            sessionId: sessionId,
            summary: summary,
            highlights: highlights,
            transcript: transcript
        )
        guard updated != note.body else { return false }
        note.body = updated
        try noteStore.updateNote(note, tags: try noteStore.tags(for: noteId), versionReason: .aiEdit)
        return true
    }
}
