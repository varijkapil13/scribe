// Scribe/Intelligence/Semantic/SemanticRelatedSearch.swift
import Foundation
import GRDB

/// The "Related notes" section of universal search: notes whose content (or
/// whose meeting transcript) is semantically close to the query, even when
/// they share no keyword with it. Only shown while "Semantic search
/// (on-device)" is on.
enum SemanticRelatedSearch {

    static let sectionId = "related"
    static let sectionTitle = "Related notes"
    static let defaultLimit = 5
    /// Queries shorter than this aren't worth embedding.
    static let minimumQueryLength = 3

    /// A related note candidate (already resolved to its note).
    struct Candidate: Equatable, Sendable {
        var noteId: String
        var title: String
        var snippet: String
    }

    // MARK: - Pure

    /// Builds the section from best-first candidates: one row per note,
    /// skipping notes the keyword "Notes" section already lists. nil when
    /// nothing is left.
    nonisolated static func section(from candidates: [Candidate],
                                    excludingNoteIds excluded: Set<String>,
                                    limit: Int = defaultLimit) -> SearchResultSection? {
        var seen = excluded
        var results: [SearchResult] = []
        for candidate in candidates where seen.insert(candidate.noteId).inserted {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(SearchResult(
                id: "related-\(candidate.noteId)",
                title: title.isEmpty ? "(Untitled)" : title,
                snippet: String(SemanticChunker.collapseWhitespace(candidate.snippet).prefix(80)),
                destination: .note(candidate.noteId),
                icon: "sparkles"
            ))
            if results.count >= limit { break }
        }
        return results.isEmpty ? nil : SearchResultSection(id: sectionId, title: sectionTitle, results: results)
    }

    /// Note ids listed by the keyword notes section.
    nonisolated static func listedNoteIds(in sections: [SearchResultSection]) -> Set<String> {
        var ids = Set<String>()
        for section in sections where section.id == "notes" {
            for result in section.results {
                if case .note(let id) = result.destination { ids.insert(id) }
            }
        }
        return ids
    }

    /// Resolves hits to their notes (a transcript hit counts for the note
    /// its session belongs to), keeping the hits' order.
    static func candidates(for hits: [SemanticHit], _ db: Database) throws -> [Candidate] {
        let noteIds = Set(hits.filter { $0.sourceType == .note }.map(\.sourceId))
        let sessionIds = Set(hits.filter { $0.sourceType == .session }.map(\.sourceId))

        var sessionNote: [String: String] = [:]
        if !sessionIds.isEmpty {
            let ids = Array(sessionIds)
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: "SELECT id, noteId FROM sessions WHERE id IN (\(marks))",
                                        arguments: StatementArguments(ids)) {
                let id: String = row["id"]
                if let noteId = row["noteId"] as String? { sessionNote[id] = noteId }
            }
        }
        let allNoteIds = Array(noteIds.union(sessionNote.values))
        var titles: [String: String] = [:]
        if !allNoteIds.isEmpty {
            let marks = Array(repeating: "?", count: allNoteIds.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: "SELECT id, title FROM notes WHERE id IN (\(marks))",
                                        arguments: StatementArguments(allNoteIds)) {
                let id: String = row["id"]
                titles[id] = (row["title"] as String?) ?? ""
            }
        }

        var out: [Candidate] = []
        for hit in hits {
            let noteId: String? = hit.sourceType == .note ? hit.sourceId : sessionNote[hit.sourceId]
            guard let noteId, let title = titles[noteId] else { continue }
            out.append(Candidate(noteId: noteId, title: title, snippet: hit.text))
        }
        return out
    }

    // MARK: - Live

    /// Related-note candidates for `query`, best first; empty when semantic
    /// search is off, the query is too short or nothing related was found.
    /// The model and database work runs off the main actor. Inputs and
    /// output are plain Sendable values so any caller can await it.
    static func relatedCandidates(query: String) async -> [Candidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryLength,
              let provider = SemanticSearchSettings.activeProvider() else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [Candidate] in
            let hits = provider.semanticHits(for: trimmed, limit: 30, sourceTypes: nil)
            guard !hits.isEmpty else { return [] }
            return (try? DatabaseManager.shared.database.read { db in
                try SemanticRelatedSearch.candidates(for: hits, db)
            }) ?? []
        }.value
    }
}
