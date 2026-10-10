import Foundation

/// A follow-up email ready to hand to Mail.
struct FollowUpEmailDraft: Equatable, Sendable {
    var subject: String
    var body: String
    /// Attendee email addresses.
    var recipients: [String]
    /// True when the body came from the on-device model.
    var usedModel: Bool

    init(subject: String, body: String, recipients: [String], usedModel: Bool = false) {
        self.subject = subject
        self.body = body
        self.recipients = recipients
        self.usedModel = usedModel
    }
}

/// Pure pieces of the "Draft follow-up email" action: recipients from the
/// calendar attendees, a deterministic template built from the summary and
/// action items (used when Apple Intelligence is unavailable or fails), and
/// parsing the model's "Subject: …" reply.
enum FollowUpEmailComposer {

    // MARK: Recipients

    /// Valid-looking, de-duplicated (case-insensitive) attendee emails, in
    /// invite order, minus `excluding` (e.g. the user's own addresses).
    nonisolated static func recipients(from attendees: [CalendarAttendee], excluding: Set<String> = []) -> [String] {
        let excluded = Set(excluding.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for attendee in attendees {
            guard let raw = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isPlausibleEmail(raw) else { continue }
            let key = raw.lowercased()
            guard !excluded.contains(key), seen.insert(key).inserted else { continue }
            out.append(raw)
        }
        return out
    }

    /// `local@domain.tld`, no spaces — enough to keep junk out of the To: line.
    nonisolated static func isPlausibleEmail(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."),
              dot != domain.startIndex,
              domain.index(after: dot) != domain.endIndex else { return false }
        return true
    }

    // MARK: Subject

    /// "Follow-up: Weekly Sync (Oct 10, 2026)".
    nonisolated static func subject(title: String, dateLabel: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = clean.isEmpty ? "our meeting" : clean
        let date = dateLabel.trimmingCharacters(in: .whitespaces)
        return date.isEmpty ? "Follow-up: \(name)" : "Follow-up: \(name) (\(date))"
    }

    // MARK: Template

    /// One action-item line: "Send the deck — Priya (due Friday)".
    nonisolated static func actionLine(_ item: ActionItem) -> String {
        var line = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let owner = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            line += " — \(owner)"
        }
        if let due = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            line += " (due \(due))"
        }
        return line
    }

    /// Deterministic follow-up email body.
    ///
    /// - Parameters:
    ///   - summary: the stored meeting summary, if one was generated.
    ///   - fallbackSummary: prose used when there's no stored summary (e.g.
    ///     the live copilot's rolling summary).
    ///   - highlights: bookmarked moments, already formatted.
    nonisolated static func templateBody(
        title: String,
        summary: MeetingSummary?,
        fallbackSummary: String?,
        actionItems: [ActionItem],
        highlights: [String],
        attendeeFirstNames: [String]
    ) -> String {
        var parts: [String] = []
        let names = attendeeFirstNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        parts.append(names.isEmpty ? "Hi all," : "Hi \(joinNames(names)),")

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingName = cleanTitle.isEmpty ? "our meeting" : cleanTitle
        parts.append("Thanks for joining \(meetingName). Here's a quick recap.")

        let recap = (summary?.summary ?? fallbackSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !recap.isEmpty {
            parts.append("Summary\n\(recap)")
        }
        if let decisions = summary?.keyDecisions.filter({ !$0.isEmpty }), !decisions.isEmpty {
            parts.append("Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        let actions = actionItems.map { actionLine($0) }.filter { !$0.isEmpty }
        if !actions.isEmpty {
            parts.append("Action items\n" + actions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let questions = summary?.followUpQuestions.filter({ !$0.isEmpty }), !questions.isEmpty {
            parts.append("Open questions\n" + questions.map { "- \($0)" }.joined(separator: "\n"))
        }
        let marked = highlights.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !marked.isEmpty {
            parts.append("Highlights\n" + marked.map { $0.hasPrefix("- ") ? $0 : "- \($0)" }.joined(separator: "\n"))
        }
        if recap.isEmpty && actions.isEmpty && marked.isEmpty {
            parts.append("I'll share notes and next steps shortly.")
        }
        parts.append("Let me know if I missed anything.\n\nBest,")
        return parts.joined(separator: "\n\n")
    }

    /// The full template draft.
    nonisolated static func template(
        title: String,
        dateLabel: String,
        summary: MeetingSummary?,
        fallbackSummary: String?,
        actionItems: [ActionItem],
        highlights: [String],
        attendees: [CalendarAttendee]
    ) -> FollowUpEmailDraft {
        FollowUpEmailDraft(
            subject: subject(title: title, dateLabel: dateLabel),
            body: templateBody(
                title: title,
                summary: summary,
                fallbackSummary: fallbackSummary,
                actionItems: actionItems,
                highlights: highlights,
                attendeeFirstNames: firstNames(attendees)
            ),
            recipients: recipients(from: attendees),
            usedModel: false
        )
    }

    /// First names of attendees with a name (emails alone are skipped),
    /// capped so the greeting stays short; more than four reads "all".
    nonisolated static func firstNames(_ attendees: [CalendarAttendee]) -> [String] {
        let names = attendees.compactMap { attendee -> String? in
            let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("@") else { return nil }
            return name.split(separator: " ").first.map(String.init)
        }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        return unique.count > 4 ? [] : unique
    }

    /// "Ana", "Ana and Ben", "Ana, Ben and Cy".
    nonisolated static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default:
            return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    // MARK: Model output

    /// Splits a model reply into subject + body. The subject comes from a
    /// leading "Subject:" line (markdown emphasis tolerated); without one,
    /// `fallbackSubject` is used and the whole reply is the body.
    nonisolated static func parseModelEmail(_ text: String, fallbackSubject: String) -> (subject: String, body: String) {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        var subject: String?
        var bodyLines: [String] = []
        for line in lines {
            if subject == nil {
                let stripped = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*#_")))
                if stripped.lowercased().hasPrefix("subject:") {
                    let value = stripped.dropFirst("subject:".count)
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_")))
                    subject = value.isEmpty ? nil : value
                    if subject != nil { continue }
                }
            }
            bodyLines.append(line)
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject ?? fallbackSubject, body)
    }

    /// Splits a free-form "To:" field ("a@x.com, b@y.com; c@z.com") into
    /// plausible addresses, de-duplicated case-insensitively.
    nonisolated static func parseRecipients(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)
        let parts = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { isPlausibleEmail($0) }
        var seen = Set<String>()
        return parts.filter { seen.insert($0.lowercased()).inserted }
    }

    /// `mailto:` URL for the draft — the fallback when the Mail sharing
    /// service isn't available.
    nonisolated static func mailtoURL(for draft: FollowUpEmailDraft) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.recipients.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body),
        ]
        return components.url
    }

    // MARK: Sharing the summary

    /// Plain-text/markdown version of a summary for ShareLink / the sharing
    /// picker.
    nonisolated static func summaryShareText(title: String, summary: MeetingSummary, highlights: [String]) -> String {
        var parts: [String] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("# \(cleanTitle.isEmpty ? "Meeting summary" : cleanTitle)")
        let prose = summary.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty { parts.append(prose) }
        if !summary.keyDecisions.isEmpty {
            parts.append("## Decisions\n" + summary.keyDecisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.actionItems.isEmpty {
            parts.append("## Action items\n" + summary.actionItems.map { "- \(actionLine($0))" }.joined(separator: "\n"))
        }
        if !summary.followUpQuestions.isEmpty {
            parts.append("## Open questions\n" + summary.followUpQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }
        let marked = highlights.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !marked.isEmpty {
            parts.append("## Highlights\n" + marked.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
