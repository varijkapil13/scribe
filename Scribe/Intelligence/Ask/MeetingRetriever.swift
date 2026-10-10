// Scribe/Intelligence/Ask/MeetingRetriever.swift
import Foundation
import GRDB

/// Database-backed retrieval for "Ask Scribe": pulls candidate evidence from
/// the existing full-text indexes (`segments_fts` for transcripts,
/// `notes_fts` for notes) plus meeting summaries, resolves the scope, then
/// hands everything to the pure `MeetingRetrieval` pipeline for scoring and
/// the context budget.
///
/// Read-only; safe to run off the main actor (`DatabaseManager` serialises
/// access internally).
struct MeetingRetriever: Sendable {

    let dbManager: DatabaseManager
    var budget: Int = MeetingRetrieval.defaultBudget
    /// Semantic (embedding) candidates to fuse with full-text ones. nil uses
    /// the shared on-device index when "Semantic search" is on (see
    /// `MeetingRetriever+Semantic.swift`).
    var semantic: (any SemanticCandidateProviding)?

    init(dbManager: DatabaseManager = .shared,
         budget: Int = MeetingRetrieval.defaultBudget,
         semantic: (any SemanticCandidateProviding)? = nil) {
        self.dbManager = dbManager
        self.budget = budget
        self.semantic = semantic
    }

    /// Retrieves ranked, budgeted snippets for `question` within `scope`.
    func retrieve(question: String, scope: AskScope = .all, now: Date = Date()) throws -> RetrievalResult {
        let terms = MeetingRetrieval.extractTerms(from: question)
        let filter = try resolveFilter(scope, now: now)

        let candidates: [RetrievedSnippet] = try dbManager.database.read { db in
            var found: [RetrievedSnippet] = []
            if !terms.isEmpty {
                let fts = MeetingRetrieval.ftsOrQuery(terms: terms)
                if !fts.isEmpty {
                    found += try Self.segmentCandidates(db, ftsQuery: fts)
                    found += try Self.noteCandidates(db, ftsQuery: fts)
                }
                found += try Self.summaryCandidates(db, terms: terms)
            }
            return found
        }

        // Hybrid: fuse with on-device semantic matches when available.
        let semanticMatches = (try? self.semanticCandidates(for: question)) ?? []
        var result = semanticMatches.isEmpty
            ? MeetingRetrieval.assemble(candidates: candidates, terms: terms,
                                        filter: filter, now: now, budget: budget)
            : HybridRetrieval.assemble(lexical: candidates, semantic: semanticMatches, terms: terms,
                                       filter: filter, now: now, budget: budget)
        if result.snippets.isEmpty {
            // Nothing matched (or the question had no usable terms, e.g.
            // "what happened?"): fall back to the most recent meetings in
            // scope so the model still has something to summarise.
            let recent = try dbManager.database.read { db in
                try Self.recentMeetingCandidates(db, filter: filter, limit: 8)
            }
            result = MeetingRetrieval.assemble(candidates: recent, terms: terms,
                                               filter: filter, now: now, budget: budget)
        }
        return result
    }

    // MARK: - Scope

    func resolveFilter(_ scope: AskScope, now: Date) throws -> AskScopeFilter {
        switch scope {
        case .all:
            return .unrestricted
        case .lastDays(let days):
            return AskScopeFilter(since: now.addingTimeInterval(-Double(max(days, 0)) * 86_400))
        case .notebook(let id, _):
            let pairs: [(String, String?)] = try dbManager.database.read { db in
                try Row.fetchAll(db, sql: "SELECT id, parentId FROM notebooks").map { row -> (String, String?) in
                    let nid: String = row["id"]
                    let parent: String? = row["parentId"]
                    return (nid, parent)
                }
            }
            return AskScopeFilter(notebookIds: Self.descendants(of: id, pairs: pairs))
        case .person(let key, _):
            let people = try PeopleRepository(dbManager: dbManager).loadPeople()
            let person = people.first { $0.id == key || $0.aliases.contains(key) }
            let noteIds = Set(person?.meetings.compactMap(\.noteId) ?? [])
            return AskScopeFilter(noteIds: noteIds)
        }
    }

    /// `rootId` plus every notebook nested beneath it.
    nonisolated static func descendants(of rootId: String, pairs: [(String, String?)]) -> Set<String> {
        var children: [String: [String]] = [:]
        for (id, parent) in pairs {
            if let parent { children[parent, default: []].append(id) }
        }
        var out: Set<String> = [rootId]
        var queue = [rootId]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where out.insert(child).inserted {
                queue.append(child)
            }
        }
        return out
    }

    // MARK: - Candidate queries

    private static func segmentCandidates(_ db: Database, ftsQuery: String) throws -> [RetrievedSnippet] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT seg.id AS segId, seg.sessionId AS sessionId, seg.speaker AS speaker,
                   seg.text AS text, s.title AS sessionTitle, s.createdAt AS createdAt,
                   s.noteId AS noteId, n.title AS noteTitle, n.notebookId AS notebookId
            FROM segments_fts
            JOIN segments seg ON seg.id = segments_fts.rowid
            JOIN sessions s ON s.id = seg.sessionId
            LEFT JOIN notes n ON n.id = s.noteId
            WHERE segments_fts MATCH ?
            ORDER BY bm25(segments_fts)
            LIMIT 300
            """, arguments: [ftsQuery])
        return rows.map { row -> RetrievedSnippet in
            let segId: Int64 = row["segId"]
            return RetrievedSnippet(
                id: "seg:\(segId)",
                kind: .transcript,
                sessionId: row["sessionId"],
                noteId: row["noteId"],
                noteTitle: (row["noteTitle"] as String?) ?? "",
                sessionTitle: row["sessionTitle"],
                notebookId: row["notebookId"],
                date: (row["createdAt"] as Date?) ?? Date.distantPast,
                speaker: row["speaker"],
                text: (row["text"] as String?) ?? ""
            )
        }
    }

    /// Locked notes (excerpt = `LockedNoteEnvelope.excerptPlaceholder`) never
    /// reach Ask / the MCP server, not even by their clear title.
    private static func noteCandidates(_ db: Database, ftsQuery: String) throws -> [RetrievedSnippet] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT n.id AS noteId, n.title AS noteTitle, n.notebookId AS notebookId,
                   n.updatedAt AS updatedAt,
                   snippet(notes_fts, 2, '', '', '…', 48) AS snip
            FROM notes_fts
            JOIN notes n ON n.id = notes_fts.noteId
            WHERE notes_fts MATCH ?
              AND (n.bodyExcerpt IS NULL OR n.bodyExcerpt != ?)
            ORDER BY bm25(notes_fts)
            LIMIT 60
            """, arguments: [ftsQuery, LockedNoteEnvelope.excerptPlaceholder])
        return rows.compactMap { row -> RetrievedSnippet? in
            let noteId: String = row["noteId"]
            let title: String = (row["noteTitle"] as String?) ?? ""
            let snip: String = (row["snip"] as String?) ?? ""
            let text = snip.trimmingCharacters(in: .whitespacesAndNewlines)
            // Title-only hits still count — use the title as the evidence.
            let evidence = text.isEmpty ? title : text
            guard !evidence.isEmpty else { return nil }
            return RetrievedSnippet(
                id: "note:\(noteId)",
                kind: .note,
                noteId: noteId,
                noteTitle: title,
                notebookId: row["notebookId"],
                date: (row["updatedAt"] as Date?) ?? Date.distantPast,
                text: evidence
            )
        }
    }

    private static func summaryCandidates(_ db: Database, terms: [String]) throws -> [RetrievedSnippet] {
        // Terms are alphanumeric-only (see `extractTerms`), so they are safe
        // inside a LIKE pattern without escaping.
        let likeTerms = terms.filter { !$0.isEmpty }
        guard !likeTerms.isEmpty else { return [] }
        let clause = likeTerms
            .map { _ in "(ms.summary LIKE ? OR ms.key_decisions LIKE ? OR s.title LIKE ?)" }
            .joined(separator: " OR ")
        var args: [String] = []
        for term in likeTerms {
            let pattern = "%\(term)%"
            args.append(pattern)
            args.append(pattern)
            args.append(pattern)
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT ms.session_id AS sessionId, ms.summary AS summary, ms.key_decisions AS decisions,
                   s.title AS sessionTitle, s.createdAt AS createdAt, s.noteId AS noteId,
                   n.title AS noteTitle, n.notebookId AS notebookId
            FROM meeting_summaries ms
            JOIN sessions s ON s.id = ms.session_id
            LEFT JOIN notes n ON n.id = s.noteId
            WHERE \(clause)
            LIMIT 100
            """, arguments: StatementArguments(args))
        return rows.map(Self.summarySnippet(from:))
    }

    /// Most recent meetings (summary, else opening transcript lines) used
    /// when the question has no matchable terms or nothing matched.
    private static func recentMeetingCandidates(_ db: Database,
                                                filter: AskScopeFilter,
                                                limit: Int) throws -> [RetrievedSnippet] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id AS sessionId, s.title AS sessionTitle, s.createdAt AS createdAt,
                   s.noteId AS noteId, n.title AS noteTitle, n.notebookId AS notebookId,
                   ms.summary AS summary, ms.key_decisions AS decisions
            FROM sessions s
            LEFT JOIN notes n ON n.id = s.noteId
            LEFT JOIN meeting_summaries ms ON ms.session_id = s.id
            ORDER BY s.createdAt DESC
            LIMIT 300
            """)
        var out: [RetrievedSnippet] = []
        for row in rows {
            var snippet = summarySnippet(from: row)
            guard filter.allows(snippet) else { continue }
            if (row["summary"] as String?) == nil {
                let sessionId: String = row["sessionId"]
                let lines = try Row.fetchAll(db, sql: """
                    SELECT speaker, text FROM segments WHERE sessionId = ?
                    ORDER BY startMs ASC LIMIT 12
                    """, arguments: [sessionId])
                let text = lines.map { line -> String in
                    let speaker: String = (line["speaker"] as String?) ?? ""
                    let body: String = (line["text"] as String?) ?? ""
                    return speaker.isEmpty ? body : "\(speaker): \(body)"
                }.joined(separator: " ")
                guard !text.isEmpty else { continue }
                snippet.kind = .transcript
                snippet.id = "open:\(sessionId)"
                snippet.text = text
            }
            out.append(snippet)
            if out.count >= limit { break }
        }
        return out
    }

    private static func summarySnippet(from row: Row) -> RetrievedSnippet {
        let sessionId: String = row["sessionId"]
        let summary: String = (row["summary"] as String?) ?? ""
        let decisionsJSON: String = (row["decisions"] as String?) ?? "[]"
        let decisions = (try? JSONDecoder().decode([String].self, from: Data(decisionsJSON.utf8))) ?? []
        var text = summary
        if !decisions.isEmpty {
            text += (text.isEmpty ? "" : " ") + "Decisions: " + decisions.joined(separator: "; ")
        }
        return RetrievedSnippet(
            id: "sum:\(sessionId)",
            kind: .summary,
            sessionId: sessionId,
            noteId: row["noteId"],
            noteTitle: (row["noteTitle"] as String?) ?? "",
            sessionTitle: row["sessionTitle"],
            notebookId: row["notebookId"],
            date: (row["createdAt"] as Date?) ?? Date.distantPast,
            text: text
        )
    }
}
