// Scribe/Intelligence/Ask/MeetingRetrieval.swift
import Foundation

// MARK: - Scope

/// What slice of the meeting archive an "Ask Scribe" question is answered
/// against. One scope at a time — the picker in the Ask view and the
/// `scope` argument of the `ask_meetings` MCP tool both map onto this.
enum AskScope: Hashable, Sendable {
    /// Every meeting, note and summary.
    case all
    /// Notes filed in a notebook (folder) or any of its sub-notebooks, plus
    /// the meetings bound to those notes.
    case notebook(id: String, name: String)
    /// Meetings a person appeared in (see `PeopleIndex`), plus their notes.
    case person(key: String, name: String)
    /// Anything dated within the last N days.
    case lastDays(Int)

    var label: String {
        switch self {
        case .all:                     return "All meetings"
        case .notebook(_, let name):   return "Notebook: \(name)"
        case .person(_, let name):     return "Person: \(name)"
        case .lastDays(let days):      return "Last \(days) days"
        }
    }
}

// MARK: - Snippet

/// A single piece of retrieved evidence — a transcript line, a meeting
/// summary, or a passage from a note — scored against the question.
struct RetrievedSnippet: Identifiable, Hashable, Sendable {

    enum Kind: String, Hashable, Sendable {
        case transcript
        case summary
        case note
    }

    /// Stable id: `seg:<rowid>`, `sum:<sessionId>`, `note:<noteId>` …
    var id: String
    var kind: Kind
    /// Session the snippet came from (nil for plain notes).
    var sessionId: String?
    /// The note this snippet belongs to — for transcripts/summaries this is
    /// the meeting note the session is bound to.
    var noteId: String?
    /// Title of `noteId`'s note (empty when unknown). Used for `[[…]]`
    /// citations so they resolve like any other wiki-link.
    var noteTitle: String
    /// Title of the session, when the snippet came from a recording.
    var sessionTitle: String?
    /// Notebook the owning note is filed in (nil = Inbox).
    var notebookId: String?
    /// When the meeting happened / the note was last edited.
    var date: Date
    /// Speaker label for transcript lines.
    var speaker: String?
    /// Snippet text (already trimmed to the per-snippet budget once ranked).
    var text: String
    /// Ranking score; higher is better. Filled in by `MeetingRetrieval.rank`.
    var score: Double = 0

    init(id: String,
         kind: Kind,
         sessionId: String? = nil,
         noteId: String? = nil,
         noteTitle: String = "",
         sessionTitle: String? = nil,
         notebookId: String? = nil,
         date: Date,
         speaker: String? = nil,
         text: String,
         score: Double = 0) {
        self.id = id
        self.kind = kind
        self.sessionId = sessionId
        self.noteId = noteId
        self.noteTitle = noteTitle
        self.sessionTitle = sessionTitle
        self.notebookId = notebookId
        self.date = date
        self.speaker = speaker
        self.text = text
        self.score = score
    }

    /// The title cited in answers as `[[title]]`: the note title when the
    /// snippet belongs to a note, otherwise the session title.
    var citationTitle: String {
        let trimmed = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let session = (sessionTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isEmpty ? "Untitled" : session
    }

    /// Groups snippets that come from the same meeting / note so the
    /// per-source cap keeps the context diverse.
    var sourceKey: String {
        if let sessionId { return "s:\(sessionId)" }
        if let noteId { return "n:\(noteId)" }
        return id
    }
}

// MARK: - Scope filter

/// Scope resolved into concrete constraints. Every non-nil constraint must
/// pass for a snippet to be kept.
struct AskScopeFilter: Equatable, Sendable {
    /// Allowed owning-note ids.
    var noteIds: Set<String>?
    /// Allowed notebook ids (matched against the owning note's notebook).
    var notebookIds: Set<String>?
    /// Earliest allowed snippet date.
    var since: Date?

    init(noteIds: Set<String>? = nil, notebookIds: Set<String>? = nil, since: Date? = nil) {
        self.noteIds = noteIds
        self.notebookIds = notebookIds
        self.since = since
    }

    static let unrestricted = AskScopeFilter()

    func allows(_ snippet: RetrievedSnippet) -> Bool {
        if let since, snippet.date < since { return false }
        if let noteIds {
            guard let noteId = snippet.noteId, noteIds.contains(noteId) else { return false }
        }
        if let notebookIds {
            guard let notebookId = snippet.notebookId, notebookIds.contains(notebookId) else { return false }
        }
        return true
    }
}

// MARK: - Result

struct RetrievalResult: Equatable, Sendable {
    /// Query terms extracted from the question.
    var terms: [String]
    /// Ranked snippets that fit the context budget, best first.
    var snippets: [RetrievedSnippet]
    /// The prompt-ready context block built from `snippets`.
    var context: String
    /// True when relevant snippets were dropped to stay within budget.
    var truncated: Bool

    static let empty = RetrievalResult(terms: [], snippets: [], context: "", truncated: false)
}

// MARK: - Pure retrieval logic

/// Pure, database-free helpers behind `MeetingRetriever`: query-term
/// extraction, FTS query building, scoring with recency, and the strict
/// character budget that keeps the context small enough for the on-device
/// model. Kept separate so it is fully unit-testable.
enum MeetingRetrieval {

    /// Default total character budget for the context block. The on-device
    /// model has a small context window that also has to hold the
    /// instructions, the question and the answer, so stay well below it.
    static let defaultBudget = 6_000
    /// Longest a single snippet may be inside the context.
    static let defaultMaxSnippetChars = 420
    /// At most this many snippets from one meeting/note, for diversity.
    static let defaultMaxPerSource = 3

    // MARK: Term extraction

    /// Words that carry no retrieval signal in a question about meetings.
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "of", "to",
        "in", "on", "at", "by", "for", "with", "from", "about", "into", "over",
        "as", "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "did", "done", "doing", "have", "has", "had", "having",
        "can", "could", "would", "should", "will", "shall", "may", "might", "must",
        "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your", "yours",
        "he", "him", "his", "she", "her", "hers", "they", "them", "their", "theirs",
        "it", "its", "this", "that", "these", "those", "there", "here",
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "any", "anything", "anyone", "anybody", "some", "something", "someone",
        "all", "each", "every", "more", "most", "much", "many", "very", "just",
        "not", "no", "yes", "also", "too", "than", "only", "ever", "again",
        "say", "says", "said", "tell", "told", "talk", "talked", "talking",
        "discuss", "discussed", "discussing", "discussion", "mention", "mentioned",
        "meeting", "meetings", "call", "calls", "please", "give", "show", "list",
        "get", "got", "let", "make", "made", "know", "think", "thought",
        "last", "recent", "recently", "latest", "ago", "week", "weeks", "month",
        "day", "days", "today", "yesterday", "scribe",
        "happen", "happened", "happening", "going", "update", "updates"
    ]

    /// Extracts lowercase search terms from a natural-language question:
    /// splits on non-alphanumerics, drops stop words and very short tokens
    /// (keeping short alphanumerics like "q3"), de-duplicates preserving
    /// order, and caps the count.
    nonisolated static func extractTerms(from question: String, maxTerms: Int = 8) -> [String] {
        let tokens = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var out: [String] = []
        for token in tokens {
            let hasDigit = token.rangeOfCharacter(from: .decimalDigits) != nil
            let longEnough = token.count >= 3 || (token.count >= 2 && hasDigit)
            guard longEnough, !stopWords.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            out.append(token)
            if out.count >= maxTerms { break }
        }
        return out
    }

    /// FTS5 MATCH expression that ORs every term as a prefix match. Empty
    /// when there are no terms (callers must then skip the FTS query).
    nonisolated static func ftsOrQuery(terms: [String]) -> String {
        terms
            .map { term in
                term.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: " OR ")
    }

    // MARK: Ranking

    /// Lowercased alphanumeric tokens of `text`.
    nonisolated static func tokens(of text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Scores and sorts candidates, best first.
    ///
    /// Score = term relevance (IDF-weighted prefix matches, with a bonus for
    /// matches in the title and for covering more of the question's terms)
    /// × a kind weight (summaries are dense, so they get a small boost)
    /// × a recency boost (up to +50% for content from the last few weeks).
    /// Ties fall back to the newer date, then the id, so ordering is stable.
    nonisolated static func rank(_ candidates: [RetrievedSnippet],
                                 terms: [String],
                                 now: Date = Date()) -> [RetrievedSnippet] {
        guard !candidates.isEmpty else { return [] }

        let bodyTokens: [[String]] = candidates.map { tokens(of: $0.text) }
        let titleTokens: [[String]] = candidates.map { tokens(of: $0.citationTitle) }

        func matches(_ term: String, _ toks: [String]) -> Bool {
            toks.contains { $0.hasPrefix(term) }
        }

        // Document frequency per term across the candidate set.
        let n = Double(candidates.count)
        var idf: [String: Double] = [:]
        for term in terms {
            var df = 0
            for i in candidates.indices where matches(term, bodyTokens[i]) || matches(term, titleTokens[i]) {
                df += 1
            }
            idf[term] = log(1.0 + n / Double(max(df, 1)))
        }

        var scored: [RetrievedSnippet] = []
        scored.reserveCapacity(candidates.count)
        for (i, candidate) in candidates.enumerated() {
            var relevance = 0.0
            if terms.isEmpty {
                relevance = 1.0
            } else {
                var covered = 0
                for term in terms {
                    let weight = idf[term] ?? 1.0
                    let inBody = matches(term, bodyTokens[i])
                    let inTitle = matches(term, titleTokens[i])
                    if inBody { relevance += weight }
                    if inTitle { relevance += 0.5 * weight }
                    if inBody || inTitle { covered += 1 }
                }
                let coverage = Double(covered) / Double(terms.count)
                // Small floor so unmatched-but-retrieved items still order by recency.
                relevance = (relevance + 0.01) * (0.5 + coverage)
            }
            var copy = candidate
            copy.score = relevance * kindWeight(candidate.kind) * recencyBoost(date: candidate.date, now: now)
            scored.append(copy)
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
    }

    nonisolated static func kindWeight(_ kind: RetrievedSnippet.Kind) -> Double {
        switch kind {
        case .summary:    return 1.3
        case .note:       return 1.1
        case .transcript: return 1.0
        }
    }

    /// 1.0 … 1.5 — decays with a ~30-day time constant.
    nonisolated static func recencyBoost(date: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
        return 1.0 + 0.5 * exp(-ageDays / 30.0)
    }

    // MARK: Budget

    /// Walks the ranked list, trims each snippet around its first matching
    /// term, caps snippets per source, and keeps adding entries while the
    /// formatted context stays within `budget` characters. Entries that
    /// don't fit are skipped (a later, shorter one may still fit), and
    /// `truncated` reports whether anything relevant was dropped.
    ///
    /// Guarantee: `formatContext(result.snippets).count <= budget`.
    nonisolated static func applyBudget(_ ranked: [RetrievedSnippet],
                                        terms: [String],
                                        budget: Int = defaultBudget,
                                        maxSnippetChars: Int = defaultMaxSnippetChars,
                                        maxPerSource: Int = defaultMaxPerSource) -> (snippets: [RetrievedSnippet], truncated: Bool) {
        var kept: [RetrievedSnippet] = []
        var perSource: [String: Int] = [:]
        var used = 0
        var truncated = false
        var seenTexts = Set<String>()

        for candidate in ranked {
            let count = perSource[candidate.sourceKey, default: 0]
            if count >= maxPerSource { truncated = true; continue }

            var snippet = candidate
            snippet.text = excerpt(candidate.text, terms: terms, maxChars: maxSnippetChars)
            guard !snippet.text.isEmpty else { continue }
            // Drop exact duplicates (e.g. repeated filler lines).
            let dedupeKey = snippet.sourceKey + "|" + snippet.text.lowercased()
            guard seenTexts.insert(dedupeKey).inserted else { continue }

            let entry = formatEntry(index: kept.count + 1, snippet: snippet)
            let cost = entry.count + (kept.isEmpty ? 0 : 1)  // newline separator
            if used + cost > budget { truncated = true; continue }

            used += cost
            kept.append(snippet)
            perSource[candidate.sourceKey] = count + 1
        }
        return (kept, truncated)
    }

    /// Collapses whitespace and, when longer than `maxChars`, returns a
    /// window around the first occurrence of any term (with ellipses).
    nonisolated static func excerpt(_ text: String, terms: [String], maxChars: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard maxChars > 0 else { return "" }
        guard collapsed.count > maxChars else { return collapsed }

        var anchor = 0
        for term in terms {
            if let range = collapsed.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                anchor = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
                break
            }
        }
        let total = collapsed.count
        let start = max(0, min(anchor - maxChars / 3, total - maxChars))
        let startIndex = collapsed.index(collapsed.startIndex, offsetBy: start)
        let endIndex = collapsed.index(startIndex, offsetBy: maxChars)
        var out = String(collapsed[startIndex..<endIndex]).trimmingCharacters(in: .whitespaces)
        if start > 0 { out = "…" + out }
        if endIndex < collapsed.endIndex { out += "…" }
        return out
    }

    // MARK: Context formatting

    /// `yyyy-MM-dd` in the current time zone, without a shared formatter.
    nonisolated static func dayString(_ date: Date) -> String {
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// One context line: `[n] [[Title]] (2026-10-03, transcript, Alice): text`.
    nonisolated static func formatEntry(index: Int, snippet: RetrievedSnippet) -> String {
        var meta = [dayString(snippet.date), snippet.kind.rawValue]
        if let speaker = snippet.speaker?.trimmingCharacters(in: .whitespaces), !speaker.isEmpty {
            meta.append(speaker)
        }
        return "[\(index)] [[\(snippet.citationTitle)]] (\(meta.joined(separator: ", "))): \(snippet.text)"
    }

    nonisolated static func formatContext(_ snippets: [RetrievedSnippet]) -> String {
        snippets.enumerated()
            .map { formatEntry(index: $0.offset + 1, snippet: $0.element) }
            .joined(separator: "\n")
    }

    /// Full pure pipeline: scope filter → rank → budget → context.
    nonisolated static func assemble(candidates: [RetrievedSnippet],
                                     terms: [String],
                                     filter: AskScopeFilter,
                                     now: Date = Date(),
                                     budget: Int = defaultBudget) -> RetrievalResult {
        let inScope = candidates.filter { filter.allows($0) }
        let ranked = rank(inScope, terms: terms, now: now)
        let budgeted = applyBudget(ranked, terms: terms, budget: budget)
        return RetrievalResult(
            terms: terms,
            snippets: budgeted.snippets,
            context: formatContext(budgeted.snippets),
            truncated: budgeted.truncated
        )
    }

    // MARK: Prompt

    /// Instructions + context + question for the on-device model. Asks for
    /// `[[Title]]` citations so the UI can turn them into links.
    nonisolated static func buildPrompt(question: String, context: String, scopeLabel: String) -> String {
        """
        You answer questions about the user's own meetings and notes. Use ONLY \
        the numbered sources below. If they don't contain the answer, say you \
        couldn't find it in the meetings — do not guess.

        Keep the answer short (a few sentences or bullet points). After each \
        fact, cite where it came from using the source's title exactly as \
        written in double square brackets, e.g. [[Weekly Sync]].

        Scope: \(scopeLabel)

        SOURCES:
        \(context)

        QUESTION: \(question)
        """
    }

    // MARK: Citations

    /// `[[Title]]` (or `[[Title|alias]]`) anchors found in an answer, in
    /// order of first appearance, de-duplicated case-insensitively. The
    /// returned value is the lookup title (the part before any `|`).
    nonisolated static func citations(in answer: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for part in citationParts(in: answer) {
            guard case .citation(let title, _) = part else { continue }
            if seen.insert(title.lowercased()).inserted { out.append(title) }
        }
        return out
    }

    enum AnswerPart: Equatable, Sendable {
        case text(String)
        /// (lookup title, display text)
        case citation(String, String)
    }

    /// Splits an answer into plain text and `[[…]]` citation parts so the UI
    /// can render citations as links.
    nonisolated static func citationParts(in answer: String) -> [AnswerPart] {
        var parts: [AnswerPart] = []
        var rest = Substring(answer)
        while let open = rest.range(of: "[[") {
            guard let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) else { break }
            let inner = rest[open.upperBound..<close.lowerBound]
            // Nested "[[" inside — treat the outer "[[" as text and move on.
            if inner.contains("[") || inner.contains("]") || inner.trimmingCharacters(in: .whitespaces).isEmpty {
                let textEnd = open.upperBound
                parts.append(.text(String(rest[rest.startIndex..<textEnd])))
                rest = rest[textEnd...]
                continue
            }
            if open.lowerBound > rest.startIndex {
                parts.append(.text(String(rest[rest.startIndex..<open.lowerBound])))
            }
            let pieces = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let title = pieces[0].trimmingCharacters(in: .whitespaces)
            let display = pieces.count > 1
                ? pieces[1].trimmingCharacters(in: .whitespaces)
                : title
            parts.append(.citation(title, display.isEmpty ? title : display))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        // Merge adjacent text parts for tidiness.
        var merged: [AnswerPart] = []
        for part in parts {
            if case .text(let t) = part, let last = merged.last, case .text(let prev) = last {
                merged[merged.count - 1] = .text(prev + t)
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    /// Plain fallback "answer" shown when Apple Intelligence is unavailable:
    /// the top snippets, each cited.
    nonisolated static func fallbackAnswer(snippets: [RetrievedSnippet], limit: Int = 5) -> String {
        guard !snippets.isEmpty else {
            return "I couldn't find anything about that in your meetings."
        }
        let lines = snippets.prefix(limit).map { snippet -> String in
            let who = snippet.speaker.map { "\($0): " } ?? ""
            return "- \(who)\(snippet.text) — [[\(snippet.citationTitle)]]"
        }
        return "Here's what your meetings say:\n" + lines.joined(separator: "\n")
    }
}
