// Scribe/Intelligence/Semantic/HybridRanking.swift
import Foundation

/// Reciprocal rank fusion (Cormack et al.): merges several ranked lists
/// into one by summing `weight / (k + rank)` per item (rank is 1-based).
/// Rank-based, so lexical BM25-ish scores and cosine similarities never
/// have to be put on a common scale.
enum ReciprocalRankFusion {

    /// The conventional damping constant.
    static let defaultK: Double = 60

    struct Fused: Equatable, Sendable {
        var id: String
        var score: Double
    }

    /// Fuses ranked id lists (best first). Duplicate ids inside one list
    /// count once, at their best rank. Ties break by first appearance across
    /// the lists, so the result is deterministic.
    nonisolated static func fuse(_ lists: [[String]], weights: [Double]? = nil, k: Double = defaultK) -> [Fused] {
        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for (listIndex, list) in lists.enumerated() {
            let weight = weights.flatMap { listIndex < $0.count ? $0[listIndex] : nil } ?? 1
            var seenInList = Set<String>()
            var rank = 0
            for id in list {
                guard seenInList.insert(id).inserted else { continue }
                rank += 1
                scores[id, default: 0] += weight / (k + Double(rank))
                if firstSeen[id] == nil {
                    firstSeen[id] = order
                    order += 1
                }
            }
        }
        return scores
            .map { Fused(id: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (firstSeen[lhs.id] ?? 0) < (firstSeen[rhs.id] ?? 0)
            }
    }
}

/// Hybrid lexical + semantic retrieval for "Ask Scribe": the full-text
/// candidates are ranked as before (`MeetingRetrieval.rank`), the semantic
/// candidates arrive ranked by similarity, and the two lists are merged with
/// reciprocal rank fusion before the usual per-source cap and budget.
enum HybridRetrieval {

    /// Semantic list weight relative to the lexical one. Slightly below 1 so
    /// exact keyword hits still win ties.
    static let semanticWeight: Double = 0.9

    /// Full pure pipeline: scope filter → rank lexical → fuse with semantic
    /// → budget → context. `semantic` must be best-first.
    nonisolated static func assemble(lexical: [RetrievedSnippet],
                                     semantic: [RetrievedSnippet],
                                     terms: [String],
                                     filter: AskScopeFilter,
                                     now: Date = Date(),
                                     budget: Int = MeetingRetrieval.defaultBudget) -> RetrievalResult {
        let rankedLexical = MeetingRetrieval.rank(lexical.filter { filter.allows($0) }, terms: terms, now: now)
        let rankedSemantic = semantic.filter { filter.allows($0) }
        let fused = fuse(lexical: rankedLexical, semantic: rankedSemantic)
        let budgeted = MeetingRetrieval.applyBudget(fused, terms: terms, budget: budget)
        return RetrievalResult(
            terms: terms,
            snippets: budgeted.snippets,
            context: MeetingRetrieval.formatContext(budgeted.snippets),
            truncated: budgeted.truncated
        )
    }

    /// Merges two best-first snippet lists by RRF. A snippet present in both
    /// lists (same id) keeps the lexical copy's text; its score becomes the
    /// fused score.
    nonisolated static func fuse(lexical: [RetrievedSnippet], semantic: [RetrievedSnippet]) -> [RetrievedSnippet] {
        var byId: [String: RetrievedSnippet] = [:]
        for snippet in semantic where byId[snippet.id] == nil { byId[snippet.id] = snippet }
        for snippet in lexical { byId[snippet.id] = snippet }
        let fused = ReciprocalRankFusion.fuse(
            [lexical.map(\.id), semantic.map(\.id)],
            weights: [1, semanticWeight]
        )
        return fused.compactMap { entry -> RetrievedSnippet? in
            guard var snippet = byId[entry.id] else { return nil }
            snippet.score = entry.score
            return snippet
        }
    }
}
