import Foundation

// Pre-meeting brief: for an upcoming calendar event, find earlier meetings
// and notes with the same people or a similar title, and pull out what the
// user should remember (last summary, open action items, open questions).
// This file is the pure selection / ranking / rendering part — loading lives
// in `MeetingBriefRepository`.

/// Something from the past that might be relevant to an upcoming meeting.
struct MeetingBriefCandidate: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// A recorded session (with its summary / action items).
        case meeting
        /// A plain note found by title search.
        case note
    }

    /// Session id for meetings, note id for notes.
    var id: String
    var kind: Kind
    var title: String
    /// Note the meeting is bound to (meetings) / the note itself (notes).
    var noteId: String?
    var noteTitle: String?
    var date: Date
    /// EventKit id of the event the meeting was recorded for (shared by every
    /// occurrence of a recurring event).
    var calendarEventId: String?
    var attendees: [CalendarAttendee]
    /// Normalised names (`PeopleIndex.normalizedKey`) of people seen in the
    /// meeting via the People index (speakers, entities, assignees).
    var peopleKeys: Set<String>
    var summary: String?
    var openActionItems: [String]
    var openQuestions: [String]

    init(
        id: String,
        kind: Kind,
        title: String,
        noteId: String? = nil,
        noteTitle: String? = nil,
        date: Date,
        calendarEventId: String? = nil,
        attendees: [CalendarAttendee] = [],
        peopleKeys: Set<String> = [],
        summary: String? = nil,
        openActionItems: [String] = [],
        openQuestions: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.noteId = noteId
        self.noteTitle = noteTitle
        self.date = date
        self.calendarEventId = calendarEventId
        self.attendees = attendees
        self.peopleKeys = peopleKeys
        self.summary = summary
        self.openActionItems = openActionItems
        self.openQuestions = openQuestions
    }

    /// Title for links / display: the note title when there is one.
    var displayTitle: String {
        let note = (noteTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? "Untitled" : own
    }
}

/// A candidate that made the cut, with why.
struct MeetingBriefMatch: Equatable, Sendable {
    var candidate: MeetingBriefCandidate
    var score: Double
    /// Short human reasons ("Same series", "With Ana, Ben", "Similar title").
    var reasons: [String]
}

/// The brief for one upcoming event.
struct MeetingBrief: Equatable, Sendable {
    var eventId: String
    var eventStart: Date
    var eventTitle: String
    var matches: [MeetingBriefMatch]
    var openActionItems: [String]
    var openQuestions: [String]

    var isEmpty: Bool { matches.isEmpty }

    /// The most relevant earlier *meeting* (not note), if any.
    var lastMeeting: MeetingBriefMatch? {
        matches.first { $0.candidate.kind == .meeting }
    }

    /// One line for the menu: "Last: Weekly Sync · 2026-10-03 · 2 open items".
    var headline: String {
        var parts: [String] = []
        if let last = lastMeeting {
            parts.append("Last: \(last.candidate.displayTitle) · \(MeetingRetrieval.dayString(last.candidate.date))")
        } else if let first = matches.first {
            parts.append("Related: \(first.candidate.displayTitle)")
        }
        if !openActionItems.isEmpty {
            parts.append("\(openActionItems.count) open item\(openActionItems.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// Notification body (kept short — banners truncate).
    var notificationBody: String {
        var parts: [String] = []
        if let last = lastMeeting {
            var line = "Last time (\(MeetingRetrieval.dayString(last.candidate.date)))"
            if let gist = MeetingBriefBuilder.firstSentence(last.candidate.summary, maxChars: 140) {
                line += ": \(gist)"
            }
            parts.append(line)
        } else if let first = matches.first {
            parts.append("Related: \(first.candidate.displayTitle)")
        }
        if let item = openActionItems.first {
            let more = openActionItems.count > 1 ? " (+\(openActionItems.count - 1) more)" : ""
            parts.append("Open: \(SessionBookmarkFormatter.quote(item, maxChars: 90))\(more)")
        }
        return parts.joined(separator: "\n")
    }

    /// Markdown version (for copying into a note).
    var markdown: String {
        var parts: [String] = ["## Brief: \(eventTitle)"]
        if !matches.isEmpty {
            let lines = matches.map { match -> String in
                let why = match.reasons.isEmpty ? "" : " — " + match.reasons.joined(separator: ", ")
                return "- [[\(match.candidate.displayTitle)]] (\(MeetingRetrieval.dayString(match.candidate.date)))\(why)"
            }
            parts.append("### Related\n" + lines.joined(separator: "\n"))
        }
        if let last = lastMeeting, let summary = last.candidate.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append("### Last time\n" + summary)
        }
        if !openActionItems.isEmpty {
            parts.append("### Open action items\n" + openActionItems.map { "- [ ] \($0)" }.joined(separator: "\n"))
        }
        if !openQuestions.isEmpty {
            parts.append("### Open questions\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

enum MeetingBriefBuilder {

    /// Minimum score for a candidate to appear in a brief.
    nonisolated static let minimumScore = 0.75
    /// Matches kept per brief.
    nonisolated static let defaultLimit = 3
    nonisolated static let actionItemLimit = 5
    nonisolated static let questionLimit = 3
    /// An attendee present in at least this share of past meetings (with at
    /// least `ubiquityMinMeetings` of them) is almost certainly the user, so
    /// they don't count as overlap.
    nonisolated static let ubiquityShare = 0.8
    nonisolated static let ubiquityMinMeetings = 4

    /// Words that say nothing about *which* meeting this is.
    nonisolated static let titleStopWords: Set<String> = [
        "the", "and", "for", "with", "meeting", "meetings", "call", "sync", "chat",
        "weekly", "daily", "monthly", "biweekly", "catch", "catchup", "up", "invitation",
        "updated", "invite", "re", "fwd", "via", "zoom", "teams", "meet", "google",
    ]

    // MARK: Keys

    /// Identity keys for an attendee: lowercased email and normalised name.
    nonisolated static func keys(for attendee: CalendarAttendee) -> Set<String> {
        var out = Set<String>()
        if let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
            out.insert(email)
        }
        let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, !name.contains("@"), PeopleIndex.isPlausibleName(name) {
            out.insert(PeopleIndex.normalizedKey(name))
        }
        return out
    }

    /// Every key of every attendee plus the People-index names.
    nonisolated static func candidateKeys(_ candidate: MeetingBriefCandidate) -> Set<String> {
        var out = candidate.peopleKeys
        for attendee in candidate.attendees { out.formUnion(keys(for: attendee)) }
        return out
    }

    /// Attendee keys that show up in nearly every past meeting (the user).
    nonisolated static func ubiquitousKeys(in candidates: [MeetingBriefCandidate]) -> Set<String> {
        let withAttendees = candidates.filter { !$0.attendees.isEmpty }
        guard withAttendees.count >= ubiquityMinMeetings else { return [] }
        var counts: [String: Int] = [:]
        for candidate in withAttendees {
            var perMeeting = Set<String>()
            for attendee in candidate.attendees { perMeeting.formUnion(keys(for: attendee)) }
            for key in perMeeting { counts[key, default: 0] += 1 }
        }
        let threshold = Double(withAttendees.count) * ubiquityShare
        return Set(counts.filter { Double($0.value) >= threshold }.map { $0.key })
    }

    // MARK: Titles

    /// Significant lowercase title words (no stop words, no bare numbers).
    nonisolated static func titleTokens(_ title: String) -> Set<String> {
        let tokens = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .filter { !$0.allSatisfy(\.isNumber) }
            .filter { !titleStopWords.contains($0) && !MeetingRetrieval.stopWords.contains($0) }
        return Set(tokens)
    }

    /// Jaccard similarity of the two titles' significant words (0…1).
    nonisolated static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = titleTokens(lhs)
        let b = titleTokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.intersection(b).count
        return Double(shared) / Double(a.union(b).count)
    }

    // MARK: Scoring

    /// Scores one candidate against the event, or nil when it isn't
    /// relevant (or isn't in the past).
    nonisolated static func score(
        event: CalendarEventInfo,
        candidate: MeetingBriefCandidate,
        ignoredKeys: Set<String> = [],
        now: Date
    ) -> MeetingBriefMatch? {
        guard candidate.date < now, candidate.date < event.start else { return nil }

        var score = 0.0
        var reasons: [String] = []

        if candidate.kind == .meeting, let eventId = candidate.calendarEventId, eventId == event.id {
            score += 3
            reasons.append("Same series")
        }

        // Attendee overlap: share of the event's (non-ubiquitous) attendees
        // seen in the candidate.
        let candKeys = candidateKeys(candidate)
        var considered = 0
        var matchedNames: [String] = []
        for attendee in event.attendees {
            let attendeeKeys = keys(for: attendee).subtracting(ignoredKeys)
            guard !attendeeKeys.isEmpty else { continue }
            considered += 1
            if !attendeeKeys.isDisjoint(with: candKeys) {
                matchedNames.append(attendee.displayName)
            }
        }
        if considered > 0, !matchedNames.isEmpty {
            score += 3 * Double(matchedNames.count) / Double(considered)
            let shown = matchedNames.prefix(3).map { name -> String in
                name.contains("@") ? name : (name.split(separator: " ").first.map(String.init) ?? name)
            }
            let more = matchedNames.count > 3 ? " +\(matchedNames.count - 3)" : ""
            reasons.append("With \(shown.joined(separator: ", "))\(more)")
        }

        let similarity = max(
            titleSimilarity(event.title, candidate.title),
            titleSimilarity(event.title, candidate.noteTitle ?? "")
        )
        if similarity >= 0.25 {
            score += 2 * similarity
            reasons.append("Similar title")
        }

        guard score >= minimumScore else { return nil }
        score *= MeetingRetrieval.recencyBoost(date: candidate.date, now: now)
        if candidate.kind == .meeting { score *= 1.1 }
        return MeetingBriefMatch(candidate: candidate, score: score, reasons: reasons)
    }

    /// Best `limit` matches, best first (ties → newer first, then id).
    nonisolated static func rank(
        event: CalendarEventInfo,
        candidates: [MeetingBriefCandidate],
        now: Date,
        limit: Int = defaultLimit
    ) -> [MeetingBriefMatch] {
        let ignored = ubiquitousKeys(in: candidates.filter { $0.date < now })
        let matches = candidates.compactMap { score(event: event, candidate: $0, ignoredKeys: ignored, now: now) }
        let sorted = matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.date != rhs.candidate.date { return lhs.candidate.date > rhs.candidate.date }
            return lhs.candidate.id < rhs.candidate.id
        }
        // A note that is just the meeting's own note would duplicate it.
        var seenNotes = Set<String>()
        var out: [MeetingBriefMatch] = []
        for match in sorted {
            if let noteId = match.candidate.noteId {
                guard seenNotes.insert(noteId).inserted else { continue }
            }
            out.append(match)
            if out.count >= max(0, limit) { break }
        }
        return out
    }

    /// The full brief for `event`.
    nonisolated static func build(
        event: CalendarEventInfo,
        candidates: [MeetingBriefCandidate],
        now: Date,
        limit: Int = defaultLimit
    ) -> MeetingBrief {
        let matches = rank(event: event, candidates: candidates, now: now, limit: limit)

        var actionSeen = Set<String>()
        var actions: [String] = []
        for match in matches {
            for item in match.candidate.openActionItems {
                let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, actionSeen.insert(clean.lowercased()).inserted else { continue }
                actions.append(clean)
            }
        }

        let questions = (matches.first(where: { $0.candidate.kind == .meeting })?.candidate.openQuestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return MeetingBrief(
            eventId: event.id,
            eventStart: event.start,
            eventTitle: event.displayTitle,
            matches: matches,
            openActionItems: Array(actions.prefix(actionItemLimit)),
            openQuestions: Array(questions.prefix(questionLimit))
        )
    }

    /// First sentence of `text`, capped, or nil when empty.
    nonisolated static func firstSentence(_ text: String?, maxChars: Int) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        var sentence = collapsed
        if let end = collapsed.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            sentence = String(collapsed[...end])
        }
        return SessionBookmarkFormatter.quote(sentence, maxChars: maxChars)
    }

    /// Stable cache / notification key for one occurrence of an event.
    nonisolated static func key(for event: CalendarEventInfo) -> String {
        "\(event.id)@\(Int(event.start.timeIntervalSince1970))"
    }
}
