import Foundation

/// Pure text / filtering helpers behind the App Intents layer (Shortcuts,
/// Siri, Spotlight). Foundation-only and free of AppIntents types so they
/// are unit-testable.
enum ScribeIntentsText {

    // MARK: - Appending

    /// Appends `text` to a note body as its own paragraph: trailing whitespace
    /// of the body is trimmed and one blank line separates the two. Blank
    /// `text` leaves the body unchanged.
    nonisolated static func append(_ text: String, to body: String) -> String {
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return body }
        var base = body
        while let last = base.last, last.isWhitespace { base.removeLast() }
        if base.isEmpty { return addition + "\n" }
        return base + "\n\n" + addition + "\n"
    }

    // MARK: - Titles

    /// A display title: the trimmed title, or `fallback` when it is blank.
    nonisolated static func displayTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Matching

    /// True when every whitespace-separated token of `query` occurs in any of
    /// `fields` (case- and diacritic-insensitive). A blank query matches.
    nonisolated static func matches(query: String, in fields: [String]) -> Bool {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            fields.contains { field in
                field.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Sessions (meetings) whose title, calendar-event title or attendee names
    /// match `query`, in their original order.
    nonisolated static func sessions(_ sessions: [Session], matching query: String) -> [Session] {
        sessions.filter { session in
            var fields = [session.title]
            if let eventTitle = session.calendarEventTitle { fields.append(eventTitle) }
            fields.append(contentsOf: session.attendees.map(\.name))
            return matches(query: query, in: fields)
        }
    }

    /// `items` reordered to follow `ids` (the order an entity query was asked
    /// for). Ids with no matching item are skipped; duplicates appear once.
    nonisolated static func ordered<Item>(_ items: [Item], byIds ids: [String], id: (Item) -> String) -> [Item] {
        var byId: [String: Item] = [:]
        for item in items where byId[id(item)] == nil {
            byId[id(item)] = item
        }
        var seen = Set<String>()
        var result: [Item] = []
        for key in ids where seen.insert(key).inserted {
            if let item = byId[key] { result.append(item) }
        }
        return result
    }

    // MARK: - Meeting summary

    /// Plain-text rendering of a meeting summary for Shortcuts / Siri.
    nonisolated static func summaryText(_ summary: MeetingSummary, title: String?) -> String {
        var sections: [String] = []
        if let title, !title.isEmpty { sections.append(title) }
        let body = summary.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { sections.append(body) }
        if !summary.keyDecisions.isEmpty {
            sections.append(bulleted("Decisions", summary.keyDecisions))
        }
        if !summary.actionItems.isEmpty {
            let lines = summary.actionItems.map { item -> String in
                var line = item.description
                if let assignee = item.assignee, !assignee.isEmpty { line += " (\(assignee))" }
                if let deadline = item.deadline, !deadline.isEmpty { line += " — \(deadline)" }
                return line
            }
            sections.append(bulleted("Action items", lines))
        }
        if !summary.followUpQuestions.isEmpty {
            sections.append(bulleted("Open questions", summary.followUpQuestions))
        }
        return sections.joined(separator: "\n\n")
    }

    private nonisolated static func bulleted(_ heading: String, _ lines: [String]) -> String {
        ([heading + ":"] + lines.map { "• \($0)" }).joined(separator: "\n")
    }
}
