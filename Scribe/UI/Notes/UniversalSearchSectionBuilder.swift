// Scribe/UI/Notes/UniversalSearchSectionBuilder.swift
import Foundation

/// Pure builders that turn store outputs into the `SearchResultSection`
/// values rendered by `UniversalSearchView`.
///
/// Originally lived as `private async` methods on
/// `UniversalSearchViewModel`, which made the result-shaping rules
/// (10-item prefix, "Untitled" fallback for empty titles, filtering
/// transcript hits without a `noteId`) impossible to unit-test without
/// spinning up the full store + debounce machinery. They're pure now —
/// the VM hands off store hits and gets a section back.
enum UniversalSearchSectionBuilder {

    /// Max results we surface per section. Keeps the dropdown short on
    /// noisy queries and matches the previous inline `prefix(10)` cap.
    static let perSectionLimit = 10

    static func notesSection(from notes: [Note]) -> SearchResultSection {
        let results = notes.prefix(perSectionLimit).map { note in
            SearchResult(
                id: "note-\(note.id)",
                title: note.title.isEmpty ? "(Untitled)" : note.title,
                snippet: String(note.body.prefix(80)),
                destination: .note(note.id),
                icon: "note.text"
            )
        }
        return SearchResultSection(id: "notes", title: "Notes", results: Array(results))
    }

    static func tasksSection(from tasks: [TodoTask]) -> SearchResultSection {
        let results = tasks.prefix(perSectionLimit).map { task in
            SearchResult(
                id: "task-\(task.id)",
                title: task.title,
                snippet: String(task.notes.prefix(80)),
                destination: .task(task.id),
                icon: "checkmark.circle"
            )
        }
        return SearchResultSection(id: "tasks", title: "Tasks", results: Array(results))
    }

    /// Transcript hits deep-link to the transcript reader (`.session(id)`) so
    /// a search lands on the actual recording, not its owning note's list.
    static func transcriptsSection(from hits: [(Session, [Segment])]) -> SearchResultSection {
        let results: [SearchResult] = hits.prefix(perSectionLimit).map { pair in
            let (session, segments) = pair
            let snippet = segments.first?.text ?? ""
            return SearchResult(
                id: "transcript-\(session.id)",
                title: session.title.isEmpty ? "Untitled session" : session.title,
                snippet: String(snippet.prefix(80)),
                destination: .session(session.id),
                icon: "waveform"
            )
        }
        return SearchResultSection(id: "transcripts", title: "Transcripts", results: results)
    }
}
