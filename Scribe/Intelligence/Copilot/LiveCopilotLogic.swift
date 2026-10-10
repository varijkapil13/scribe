import Foundation

// Pure logic behind the live meeting copilot: when to refresh the rolling
// summary, how new transcript is batched into budget-sized chunks, the
// incremental prompt (previous summary + new chunk), parsing the model's
// reply, and a heuristic fallback for Macs without Apple Intelligence.
// No FoundationModels / UI here, so everything is unit-tested.

// MARK: - Values

/// One persisted transcript line of the live session.
struct LiveCopilotLine: Equatable, Sendable {
    /// Segment row id — monotonically increasing in insert order, so "lines
    /// after id N" is exactly the transcript the copilot hasn't seen yet.
    var id: Int64
    var startMs: Int
    var endMs: Int
    var speaker: String
    var text: String

    init(id: Int64, startMs: Int, endMs: Int, speaker: String, text: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }

    /// `[00:01:23] Alice: text` (speaker omitted when blank).
    var promptLine: String {
        let stamp = SessionBookmarkFormatter.promptTimestamp(ms: startMs)
        let body = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let who = speaker.trimmingCharacters(in: .whitespaces)
        return who.isEmpty ? "\(stamp) \(body)" : "\(stamp) \(who): \(body)"
    }
}

/// The rolling picture of the meeting so far.
struct LiveCopilotState: Equatable, Sendable {
    var summary: String
    var actionItems: [String]
    var openQuestions: [String]

    init(summary: String = "", actionItems: [String] = [], openQuestions: [String] = []) {
        self.summary = summary
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    static let empty = LiveCopilotState()

    var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && actionItems.isEmpty && openQuestions.isEmpty
    }
}

// MARK: - Scheduling

/// Decides when the rolling summary should be refreshed and which
/// transcript it should consume.
enum LiveCopilotScheduler {

    /// Default refresh cadence: every ~2 minutes of recording.
    nonisolated static let defaultIntervalMs = 120_000
    /// Don't bother the model for a couple of words.
    nonisolated static let minNewCharacters = 160

    /// Lines the copilot hasn't folded into its state yet, in insert order.
    nonisolated static func pendingLines(_ lines: [LiveCopilotLine], afterId lastId: Int64) -> [LiveCopilotLine] {
        lines
            .filter { $0.id > lastId && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.id < $1.id }
    }

    /// Characters of new transcript waiting.
    nonisolated static func pendingCharacters(_ lines: [LiveCopilotLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.count }
    }

    /// True when an update should run now.
    ///
    /// - A forced (on-demand) update runs whenever there's *any* new text.
    /// - Otherwise it waits for at least `minCharacters` of new text, and
    ///   for `intervalMs` of recording since the last update (or since the
    ///   start) — unless the backlog already fills a whole chunk budget, in
    ///   which case it runs early so the prompt never has to drop text.
    nonisolated static func shouldUpdate(
        elapsedMs: Int,
        lastUpdateElapsedMs: Int?,
        pendingCharacters: Int,
        intervalMs: Int,
        force: Bool,
        minCharacters: Int = LiveCopilotScheduler.minNewCharacters,
        backlogCharacters: Int = LiveCopilotPromptBuilder.chunkBudget
    ) -> Bool {
        guard pendingCharacters > 0 else { return false }
        if force { return true }
        guard pendingCharacters >= minCharacters else { return false }
        if pendingCharacters >= backlogCharacters { return true }
        let since = elapsedMs - (lastUpdateElapsedMs ?? 0)
        return since >= max(1, intervalMs)
    }

    /// Packs pending lines into chunks whose formatted text fits
    /// `chunkBudget` characters, at most `maxChunks` of them. Lines that
    /// don't fit stay pending for the next update. A single line longer than
    /// the budget gets a chunk of its own (the prompt builder truncates it).
    nonisolated static func batches(
        _ lines: [LiveCopilotLine],
        chunkBudget: Int = LiveCopilotPromptBuilder.chunkBudget,
        maxChunks: Int = 3
    ) -> [[LiveCopilotLine]] {
        var out: [[LiveCopilotLine]] = []
        var current: [LiveCopilotLine] = []
        var used = 0
        for line in lines {
            let length = line.promptLine.count
            if !current.isEmpty, used + 1 + length > chunkBudget {
                out.append(current)
                if out.count >= max(1, maxChunks) { return out }
                current = []
                used = 0
            }
            used += current.isEmpty ? length : 1 + length
            current.append(line)
        }
        if !current.isEmpty, out.count < maxChunks { out.append(current) }
        return out
    }
}

// MARK: - Prompt

/// Builds the incremental prompt: previous state + the new transcript chunk,
/// kept inside the on-device model's small context window.
enum LiveCopilotPromptBuilder {

    /// Max characters of new transcript per prompt.
    nonisolated static let chunkBudget = 3_500
    /// Max characters of the previous summary carried into the prompt.
    nonisolated static let previousSummaryBudget = 1_200
    /// Max characters of each carried list item.
    nonisolated static let listItemBudget = 200
    /// Items kept per list.
    nonisolated static let listLimit = 8

    nonisolated static let instructions = """
    You keep live notes for a meeting that is still in progress. You receive \
    the notes so far and the newest part of the transcript. Update the notes: \
    keep what is still true, add what is new, and stay brief. Never invent \
    facts that are not in the transcript or the previous notes.
    """

    /// The full user prompt for one incremental update.
    nonisolated static func prompt(
        title: String,
        previous: LiveCopilotState,
        chunk: [LiveCopilotLine],
        highlightedMs: [Int] = []
    ) -> String {
        let transcript = TranscriptBudget.truncate(
            chunk.map(\.promptLine).joined(separator: "\n"),
            maxChars: chunkBudget
        )
        let previousSummary = previous.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = previousSummary.isEmpty
            ? "(nothing yet — this is the start of the meeting)"
            : TranscriptBudget.truncate(previousSummary, maxChars: previousSummaryBudget)

        var sections: [String] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("MEETING: \(cleanTitle.isEmpty ? "Untitled meeting" : cleanTitle)")
        sections.append("NOTES SO FAR:\n\(summaryText)")
        sections.append("ACTION ITEMS SO FAR:\n\(bulletList(previous.actionItems))")
        sections.append("OPEN QUESTIONS SO FAR:\n\(bulletList(previous.openQuestions))")

        if let first = chunk.first, let last = chunk.last {
            let lower = first.startMs
            let upper = max(last.endMs, last.startMs)
            let inChunk = highlightedMs.filter { $0 >= lower - SessionBookmarkFormatter.lookbackMs && $0 <= upper }
            if !inChunk.isEmpty {
                let stamps = inChunk.sorted().map(SessionBookmarkFormatter.promptTimestamp(ms:))
                sections.append("The user marked these moments as important: \(stamps.joined(separator: ", ")). Make sure they are reflected.")
            }
        }

        sections.append("NEW TRANSCRIPT:\n\(transcript)")
        sections.append("""
        Reply in exactly this format, with no other text:
        SUMMARY:
        <2-5 sentences covering the whole meeting so far>
        ACTION ITEMS:
        - <owner if known: task> (one per line, or "- None")
        OPEN QUESTIONS:
        - <question still unanswered> (one per line, or "- None")
        """)
        return sections.joined(separator: "\n\n")
    }

    /// Previous list items, capped in count and length.
    nonisolated static func bulletList(_ items: [String]) -> String {
        let kept = items.suffix(listLimit).map { item -> String in
            let collapsed = item.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return "- " + (collapsed.count > listItemBudget ? String(collapsed.prefix(listItemBudget)) + "…" : collapsed)
        }
        return kept.isEmpty ? "- None" : kept.joined(separator: "\n")
    }

    // MARK: Parsing

    private enum Section { case summary, actions, questions }

    /// Parses the model's reply. Missing sections keep the previous values;
    /// a reply without any recognised header is taken as the summary.
    /// Returns nil for an empty reply.
    nonisolated static func parse(_ response: String, previous: LiveCopilotState) -> LiveCopilotState? {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var summaryLines: [String] = []
        var actions: [String] = []
        var questions: [String] = []
        var sawSummary = false, sawActions = false, sawQuestions = false
        var current: Section?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let (header, rest) = headerMatch(line)
            if let header {
                current = header
                switch header {
                case .summary: sawSummary = true
                case .actions: sawActions = true
                case .questions: sawQuestions = true
                }
                if !rest.isEmpty {
                    append(rest, to: header, summary: &summaryLines, actions: &actions, questions: &questions)
                }
                continue
            }
            guard !line.isEmpty, let section = current else { continue }
            append(line, to: section, summary: &summaryLines, actions: &actions, questions: &questions)
        }

        if !sawSummary && !sawActions && !sawQuestions {
            let stripped = stripMarkdownNoise(text)
            return LiveCopilotState(summary: stripped,
                                    actionItems: previous.actionItems,
                                    openQuestions: previous.openQuestions)
        }

        let summary = summaryLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return LiveCopilotState(
            summary: sawSummary && !summary.isEmpty ? summary : previous.summary,
            actionItems: sawActions ? dedupe(actions).suffix(listLimit).map { $0 } : previous.actionItems,
            openQuestions: sawQuestions ? dedupe(questions).suffix(listLimit).map { $0 } : previous.openQuestions
        )
    }

    private static func append(
        _ line: String,
        to section: Section,
        summary: inout [String],
        actions: inout [String],
        questions: inout [String]
    ) {
        switch section {
        case .summary:
            let cleaned = stripMarkdownNoise(line)
            if !cleaned.isEmpty { summary.append(cleaned) }
        case .actions:
            if let item = listItem(line) { actions.append(item) }
        case .questions:
            if let item = listItem(line) { questions.append(item) }
        }
    }

    /// Recognises "SUMMARY:", "**Action items:**", "## Open questions" …
    /// and returns any text after the colon on the same line.
    private static func headerMatch(_ line: String) -> (Section?, String) {
        var stripped = line
        while let first = stripped.first, "#*_ ".contains(first) { stripped.removeFirst() }
        let lower = stripped.lowercased()
        let table: [(String, Section)] = [
            ("summary", .summary),
            ("notes", .summary),
            ("action items", .actions),
            ("action item", .actions),
            ("open questions", .questions),
            ("questions", .questions),
        ]
        for (name, section) in table where lower.hasPrefix(name) {
            var rest = String(stripped.dropFirst(name.count))
            while let first = rest.first, "*_ ".contains(first) { rest.removeFirst() }
            guard rest.isEmpty || rest.hasPrefix(":") else { continue }
            if rest.hasPrefix(":") { rest.removeFirst() }
            rest = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_")))
            return (section, rest)
        }
        return (nil, "")
    }

    /// The text of a bullet / numbered list line, or nil for "None" /
    /// placeholders.
    nonisolated static func listItem(_ line: String) -> String? {
        var item = line.trimmingCharacters(in: .whitespaces)
        if let first = item.first, "-*•".contains(first) {
            item.removeFirst()
        } else if let dot = item.firstIndex(where: { $0 == "." || $0 == ")" }),
                  item[item.startIndex..<dot].allSatisfy(\.isNumber),
                  item.startIndex != dot {
            item = String(item[item.index(after: dot)...])
        }
        item = item.trimmingCharacters(in: .whitespaces)
        item = stripMarkdownNoise(item)
        let lower = item.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if item.isEmpty || lower == "none" || lower == "n/a" || lower.hasPrefix("none ") || lower == "none yet" {
            return nil
        }
        return item
    }

    private static func stripMarkdownNoise(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive de-duplication keeping the *last* occurrence order.
    nonisolated static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let key = item.lowercased()
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }
}

// MARK: - Heuristic fallback

/// Keeps the copilot useful without Apple Intelligence: pulls likely action
/// items (commitments, requests) and open questions straight out of the new
/// transcript. No summary prose — that needs the model.
enum LiveCopilotHeuristics {

    /// Lowercased cues that usually introduce a commitment or a request.
    nonisolated static let actionCues: [String] = [
        "i'll ", "i will ", "we'll ", "we will ", "i'm going to ", "we're going to ",
        "let's ", "action item", "follow up", "follow-up", "to do", "todo",
        "can you ", "could you ", "please ", "need to ", "needs to ", "make sure ",
        "by monday", "by tuesday", "by wednesday", "by thursday", "by friday",
        "by tomorrow", "by end of", "by eod", "next week",
    ]

    nonisolated static func isQuestion(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        // Very short "right?" / "okay?" tags aren't open questions.
        return trimmed.hasSuffix("?") && trimmed.split(separator: " ").count >= 4
    }

    nonisolated static func isActionItem(_ sentence: String) -> Bool {
        let lower = " " + sentence.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        guard sentence.split(separator: " ").count >= 4, !isQuestion(sentence) || lower.contains("can you ") || lower.contains("could you ") else {
            return false
        }
        return actionCues.contains { lower.contains($0) }
    }

    /// Splits text into sentences on . ! ? (keeping the terminator).
    nonisolated static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Previous state plus anything new found in `lines`. Lists keep the most
    /// recent `LiveCopilotPromptBuilder.listLimit` entries.
    nonisolated static func update(previous: LiveCopilotState, lines: [LiveCopilotLine]) -> LiveCopilotState {
        var actions = previous.actionItems
        var questions = previous.openQuestions
        for line in lines {
            let speaker = line.speaker.trimmingCharacters(in: .whitespaces)
            for sentence in sentences(line.text) {
                let quoted = SessionBookmarkFormatter.quote(sentence, maxChars: LiveCopilotPromptBuilder.listItemBudget)
                let attributed = speaker.isEmpty ? quoted : "\(speaker): \(quoted)"
                if isActionItem(sentence) {
                    actions.append(attributed)
                } else if isQuestion(sentence) {
                    questions.append(attributed)
                }
            }
        }
        let limit = LiveCopilotPromptBuilder.listLimit
        return LiveCopilotState(
            summary: previous.summary,
            actionItems: Array(LiveCopilotPromptBuilder.dedupe(actions).suffix(limit)),
            openQuestions: Array(LiveCopilotPromptBuilder.dedupe(questions).suffix(limit))
        )
    }
}
