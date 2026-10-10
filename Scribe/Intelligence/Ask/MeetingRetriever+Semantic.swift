// Scribe/Intelligence/Ask/MeetingRetriever+Semantic.swift
import Foundation
import GRDB

/// The semantic half of hybrid "Ask Scribe" retrieval: nearest chunks from
/// the on-device embedding index, turned into `RetrievedSnippet`s that
/// `HybridRetrieval` fuses with the full-text candidates.
extension MeetingRetriever {

    /// How many nearest chunks to consider per question.
    static let semanticCandidateLimit = 40

    /// Semantic candidates for `question`, best first; empty when no
    /// provider is active or nothing is indexed.
    func semanticCandidates(for question: String) throws -> [RetrievedSnippet] {
        guard let provider = semantic ?? SemanticSearchSettings.activeProvider() else { return [] }
        let hits = provider.semanticHits(for: question, limit: Self.semanticCandidateLimit, sourceTypes: nil)
        guard !hits.isEmpty else { return [] }
        return try dbManager.database.read { db in
            try Self.snippets(for: hits, db)
        }
    }

    /// Resolves hits into snippets with note / session metadata, keeping
    /// the hits' order. Hits whose source vanished are dropped. A note
    /// contributes one snippet (its best chunk) under the same id the
    /// full-text note candidate uses, so fusion merges the two.
    static func snippets(for hits: [SemanticHit], _ db: Database) throws -> [RetrievedSnippet] {
        let noteIds = Array(Set(hits.filter { $0.sourceType == .note }.map(\.sourceId)))
        let sessionIds = Array(Set(hits.filter { $0.sourceType == .session }.map(\.sourceId)))

        var notes: [String: Row] = [:]
        if !noteIds.isEmpty {
            let marks = Array(repeating: "?", count: noteIds.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: """
                SELECT id, title, notebookId, updatedAt FROM notes WHERE id IN (\(marks))
                """, arguments: StatementArguments(noteIds)) {
                let id: String = row["id"]
                notes[id] = row
            }
        }
        var sessions: [String: Row] = [:]
        if !sessionIds.isEmpty {
            let marks = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: """
                SELECT s.id AS id, s.title AS sessionTitle, s.createdAt AS createdAt,
                       s.noteId AS noteId, n.title AS noteTitle, n.notebookId AS notebookId
                FROM sessions s LEFT JOIN notes n ON n.id = s.noteId
                WHERE s.id IN (\(marks))
                """, arguments: StatementArguments(sessionIds)) {
                let id: String = row["id"]
                sessions[id] = row
            }
        }

        var out: [RetrievedSnippet] = []
        var seen = Set<String>()
        for hit in hits {
            switch hit.sourceType {
            case .note:
                guard let row = notes[hit.sourceId] else { continue }
                let id = "note:\(hit.sourceId)"
                guard seen.insert(id).inserted else { continue }
                out.append(RetrievedSnippet(
                    id: id,
                    kind: .note,
                    noteId: hit.sourceId,
                    noteTitle: (row["title"] as String?) ?? "",
                    notebookId: row["notebookId"],
                    date: (row["updatedAt"] as Date?) ?? Date.distantPast,
                    text: hit.text,
                    score: Double(hit.score)
                ))
            case .session:
                guard let row = sessions[hit.sourceId] else { continue }
                let id = "sem:\(hit.chunkId)"
                guard seen.insert(id).inserted else { continue }
                out.append(RetrievedSnippet(
                    id: id,
                    kind: .transcript,
                    sessionId: hit.sourceId,
                    noteId: row["noteId"],
                    noteTitle: (row["noteTitle"] as String?) ?? "",
                    sessionTitle: row["sessionTitle"],
                    notebookId: row["notebookId"],
                    date: (row["createdAt"] as Date?) ?? Date.distantPast,
                    text: hit.text,
                    score: Double(hit.score)
                ))
            }
        }
        return out
    }
}
