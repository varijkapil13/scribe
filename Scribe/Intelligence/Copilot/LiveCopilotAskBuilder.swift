import Foundation

/// "Ask now" during a recording: picks the transcript lines relevant to a
/// question (reusing `MeetingRetrieval`'s term extraction), fits them into a
/// character budget, and builds the prompt. Pure — tested without the model.
enum LiveCopilotAskBuilder {

    /// Max characters of transcript context in an "Ask now" prompt.
    nonisolated static let contextBudget = 4_500
    /// Lines shown in the no-model fallback answer.
    nonisolated static let fallbackLimit = 5

    /// Lowercased tokens of `text` (same tokenizer as `MeetingRetrieval`).
    nonisolated static func tokens(_ text: String) -> [String] {
        MeetingRetrieval.tokens(of: text)
    }

    /// Relevance of one line: matched question terms (prefix match on the
    /// text, extra weight on the speaker name), 0 when nothing matches.
    nonisolated static func score(_ line: LiveCopilotLine, terms: [String]) -> Double {
        guard !terms.isEmpty else { return 0 }
        let body = tokens(line.text)
        let speaker = tokens(line.speaker)
        var score = 0.0
        for term in terms {
            if body.contains(where: { $0.hasPrefix(term) }) { score += 1 }
            if speaker.contains(where: { $0.hasPrefix(term) }) { score += 1.5 }
        }
        return score
    }

    /// Transcript context for `question`, in chronological order.
    ///
    /// Lines matching the question's terms are taken best-first (later lines
    /// win ties — the meeting's latest word on a topic) until the budget is
    /// full. Speaker-only matches ("what did Priya say") still need a text
    /// match or come from the speaker; when nothing matches, the most recent
    /// transcript that fits is used instead.
    nonisolated static func selectContext(
        question: String,
        lines: [LiveCopilotLine],
        budget: Int = LiveCopilotAskBuilder.contextBudget
    ) -> [LiveCopilotLine] {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty, budget > 0 else { return [] }
        let terms = MeetingRetrieval.extractTerms(from: question)

        let scored = usable.enumerated()
            .map { (index: $0.offset, line: $0.element, score: score($0.element, terms: terms)) }
            .filter { $0.score > 0 }

        var picked: [(index: Int, line: LiveCopilotLine)] = []
        var used = 0
        if !scored.isEmpty {
            let ranked = scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index > rhs.index
            }
            for entry in ranked {
                let cost = entry.line.promptLine.count + (picked.isEmpty ? 0 : 1)
                if used + cost > budget { continue }
                used += cost
                picked.append((index: entry.index, line: entry.line))
            }
        }
        if picked.isEmpty {
            // No match (or nothing fit): the most recent transcript.
            for (index, line) in usable.enumerated().reversed() {
                let cost = line.promptLine.count + (picked.isEmpty ? 0 : 1)
                if used + cost > budget { break }
                used += cost
                picked.append((index: index, line: line))
            }
        }
        return picked.sorted { $0.index < $1.index }.map(\.line)
    }

    nonisolated static let instructions = """
    You answer questions about a meeting that is still in progress, using \
    only the transcript excerpts and notes provided. If they don't contain \
    the answer, say so plainly. Keep answers to a few sentences and mention \
    who said what with its [hh:mm:ss] timestamp when relevant.
    """

    /// The user prompt for one question.
    nonisolated static func prompt(question: String, context: [LiveCopilotLine], liveSummary: String) -> String {
        var parts: [String] = []
        let summary = liveSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            parts.append("LIVE NOTES SO FAR:\n" + TranscriptBudget.truncate(summary, maxChars: 800))
        }
        let transcript = context.map(\.promptLine).joined(separator: "\n")
        parts.append("TRANSCRIPT EXCERPTS:\n" + (transcript.isEmpty ? "(no transcript yet)" : transcript))
        parts.append("QUESTION: " + question.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.joined(separator: "\n\n")
    }

    /// Answer shown without Apple Intelligence: the most relevant lines.
    nonisolated static func fallbackAnswer(question: String, lines: [LiveCopilotLine]) -> String {
        let terms = MeetingRetrieval.extractTerms(from: question)
        let matches = lines.enumerated()
            .map { (index: $0.offset, line: $0.element, score: score($0.element, terms: terms)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index > rhs.index
            }
            .prefix(fallbackLimit)
            .sorted { $0.index < $1.index }
        guard !matches.isEmpty else {
            return "Nothing in the transcript so far matches that question."
        }
        let bullets = matches.map { entry -> String in
            let stamp = SessionBookmarkFormatter.shortTimestamp(ms: entry.line.startMs)
            let speaker = entry.line.speaker.trimmingCharacters(in: .whitespaces)
            let who = speaker.isEmpty ? "" : "\(speaker): "
            return "- \(stamp) \(who)\(SessionBookmarkFormatter.quote(entry.line.text, maxChars: 220))"
        }
        return "Most relevant moments so far:\n" + bullets.joined(separator: "\n")
    }
}
