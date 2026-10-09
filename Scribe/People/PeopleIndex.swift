// Scribe/People/PeopleIndex.swift
import Foundation

// MARK: - Inputs

/// One sighting of a person's name in a meeting.
struct PersonMention: Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        /// A PERSON named entity extracted from the transcript.
        case entity
        /// A (user-named) speaker label on a transcript segment.
        case speaker
        /// A calendar attendee (plugged in via `PeopleMentionSource`).
        case attendee
        /// The assignee of an action item from the meeting summary.
        case assignee
    }

    var name: String
    var sessionId: String
    var source: Source

    init(name: String, sessionId: String, source: Source) {
        self.name = name
        self.sessionId = sessionId
        self.source = source
    }
}

/// A meeting a person appeared in.
struct PersonMeeting: Identifiable, Hashable, Sendable {
    var id: String { sessionId }
    var sessionId: String
    var sessionTitle: String
    var date: Date
    /// The meeting note the session is bound to, if any.
    var noteId: String?
    var noteTitle: String?

    init(sessionId: String, sessionTitle: String, date: Date, noteId: String? = nil, noteTitle: String? = nil) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.date = date
        self.noteId = noteId
        self.noteTitle = noteTitle
    }

    /// Title used for `[[wiki links]]` to this meeting: the note title when
    /// there is one, otherwise the session title.
    var linkTitle: String {
        let note = (noteTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        let session = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isEmpty ? "Untitled meeting" : session
    }

    /// True when `linkTitle` names an actual note (so `[[…]]` resolves).
    var hasNote: Bool {
        noteId != nil && !(noteTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// An open task that may mention a person.
struct PersonTaskRef: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var dueAt: Date?
    var tags: [String]
    /// Assignee of the action item the task was converted from, if any.
    var assignee: String?

    init(id: String, title: String, dueAt: Date? = nil, tags: [String] = [], assignee: String? = nil) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.tags = tags
        self.assignee = assignee
    }
}

// MARK: - Output

/// A person aggregated across meetings.
struct Person: Identifiable, Hashable, Sendable {
    /// Normalised canonical key (e.g. `"alice smith"`). Stable across reloads.
    var id: String
    /// Best display form of the name (e.g. `"Alice Smith"`).
    var name: String
    /// Every normalised key merged into this person (always includes `id`).
    var aliases: [String]
    /// Meetings they appeared in, newest first.
    var meetings: [PersonMeeting]
    /// Open tasks whose title / tag / assignee mentions them.
    var openTasks: [PersonTaskRef]

    var meetingCount: Int { meetings.count }
}

// MARK: - Index

/// Pure aggregation of people from name mentions. No database access — see
/// `PeopleRepository` for the loader.
///
/// Normalisation: whitespace collapsed, edge punctuation and possessive
/// `'s` stripped, case- and diacritic-folded. A lone first name ("Alice")
/// is merged into a full name ("Alice Smith") only when exactly one full
/// name starts with it; with two candidates ("Alice Smith", "Alice Jones")
/// it stays a separate person rather than guessing.
enum PeopleIndex {

    /// Speaker labels and other tokens that are never a real person.
    static let genericNames: Set<String> = [
        "you", "me", "i", "we", "us", "remote", "others", "other", "them",
        "unknown", "speaker", "someone", "somebody", "everyone", "everybody",
        "guest", "host", "participant", "person", "user", "mic", "system",
        "microphone", "local"
    ]

    /// Prefixes of numbered placeholder labels ("Speaker 2", "Guest 1").
    static let numberedPrefixes: Set<String> = ["speaker", "guest", "participant", "person", "user"]

    // MARK: Normalisation

    /// Cleaned display form: collapsed whitespace, no edge punctuation,
    /// no trailing possessive.
    nonisolated static func displayName(_ raw: String) -> String {
        var words = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let edge = CharacterSet.punctuationCharacters
            .union(.symbols)
            .subtracting(CharacterSet(charactersIn: "-'’."))
        words = words.map { $0.trimmingCharacters(in: edge) }.filter { !$0.isEmpty }
        var joined = words.joined(separator: " ")
        for suffix in ["'s", "’s", "'S", "’S"] where joined.hasSuffix(suffix) {
            joined = String(joined.dropLast(suffix.count))
            break
        }
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " -'’.,"))
    }

    /// Case-, diacritic- and whitespace-insensitive key for a name.
    nonisolated static func normalizedKey(_ raw: String) -> String {
        displayName(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    /// Filters out speaker placeholders ("you", "remote", "Speaker 2"),
    /// numbers and implausibly long phrases.
    nonisolated static func isPlausibleName(_ raw: String) -> Bool {
        let key = normalizedKey(raw)
        guard key.count >= 2, key.count <= 60 else { return false }
        guard key.rangeOfCharacter(from: .letters) != nil else { return false }
        guard !genericNames.contains(key) else { return false }
        let tokens = key.split(separator: " ").map(String.init)
        guard tokens.count <= 4 else { return false }
        if tokens.count >= 2, let first = tokens.first, numberedPrefixes.contains(first),
           tokens.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return false
        }
        return true
    }

    /// Maps every key to its canonical key. Single-token keys merge into the
    /// unique multi-token key that starts with them; otherwise a key maps
    /// to itself.
    nonisolated static func canonicalKeys(for keys: Set<String>) -> [String: String] {
        var byFirstToken: [String: [String]] = [:]
        for key in keys where key.contains(" ") {
            if let first = key.split(separator: " ").first {
                byFirstToken[String(first), default: []].append(key)
            }
        }
        var out: [String: String] = [:]
        for key in keys {
            if !key.contains(" "), let fulls = byFirstToken[key], fulls.count == 1, let full = fulls.first {
                out[key] = full
            } else {
                out[key] = key
            }
        }
        return out
    }

    // MARK: Task matching

    /// Folded alphanumeric tokens.
    nonisolated static func nameTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when `task` mentions any of `matchKeys` (normalised names) in its
    /// title (as a whole-word sequence), a tag (`#alice`, `@alice-smith`),
    /// or its action-item assignee.
    nonisolated static func task(_ task: PersonTaskRef, mentionsAnyOf matchKeys: [String]) -> Bool {
        let keyTokens = matchKeys.map { nameTokens($0) }.filter { !$0.isEmpty }
        guard !keyTokens.isEmpty else { return false }

        let titleTokens = nameTokens(task.title)
        for needle in keyTokens where containsSequence(titleTokens, needle) {
            return true
        }
        for tag in task.tags {
            let tagTokens = nameTokens(tag)
            if keyTokens.contains(tagTokens) { return true }
            // "alicesmith" style tags.
            if keyTokens.contains(where: { $0.joined() == tagTokens.joined() && !tagTokens.isEmpty }) {
                return true
            }
        }
        if let assignee = task.assignee {
            let assigneeTokens = nameTokens(assignee)
            if keyTokens.contains(assigneeTokens) { return true }
        }
        return false
    }

    nonisolated static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    // MARK: Build

    /// Aggregates `mentions` into people.
    ///
    /// - Parameters:
    ///   - mentions: name sightings per session (entities, speakers, …).
    ///   - meetings: session id → meeting details. Mentions of unknown
    ///     sessions are ignored.
    ///   - tasks: open tasks to attribute to people.
    /// - Returns: people sorted by meeting count (desc), then name.
    nonisolated static func build(mentions: [PersonMention],
                                  meetings: [String: PersonMeeting],
                                  tasks: [PersonTaskRef]) -> [Person] {
        // 1. Collect plausible mentions by key.
        var displayVariants: [String: [String: Int]] = [:]   // key → display → count
        var sessionsByKey: [String: Set<String>] = [:]
        for mention in mentions where isPlausibleName(mention.name) {
            guard meetings[mention.sessionId] != nil else { continue }
            let key = normalizedKey(mention.name)
            let display = displayName(mention.name)
            displayVariants[key, default: [:]][display, default: 0] += 1
            sessionsByKey[key, default: []].insert(mention.sessionId)
        }
        guard !sessionsByKey.isEmpty else { return [] }

        // 2. Merge first names into unambiguous full names.
        let canonical = canonicalKeys(for: Set(sessionsByKey.keys))
        var groups: [String: [String]] = [:]   // canonical → member keys
        for (key, target) in canonical {
            groups[target, default: []].append(key)
        }

        // First tokens shared by several people can't be used to match tasks.
        var firstTokenCounts: [String: Int] = [:]
        for canonicalKey in groups.keys {
            if let first = canonicalKey.split(separator: " ").first {
                firstTokenCounts[String(first), default: 0] += 1
            }
        }

        // 3. Build each person.
        var people: [Person] = []
        for (canonicalKey, members) in groups {
            var sessionIds = Set<String>()
            for member in members {
                sessionIds.formUnion(sessionsByKey[member] ?? [])
            }
            let personMeetings = sessionIds
                .compactMap { meetings[$0] }
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date > rhs.date }
                    return lhs.sessionId < rhs.sessionId
                }

            let name = bestDisplayName(canonicalKey: canonicalKey,
                                       variants: displayVariants[canonicalKey] ?? [:])

            var matchKeys = Array(Set(members)).sorted()
            if canonicalKey.contains(" "),
               let first = canonicalKey.split(separator: " ").first.map(String.init),
               first.count >= 3,
               firstTokenCounts[first] == 1,
               !matchKeys.contains(first) {
                matchKeys.append(first)
            }
            let personTasks = tasks
                .filter { PeopleIndex.task($0, mentionsAnyOf: matchKeys) }
                .sorted { lhs, rhs in
                    switch (lhs.dueAt, rhs.dueAt) {
                    case let (l?, r?) where l != r: return l < r
                    case (.some, .none): return true
                    case (.none, .some): return false
                    default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                }

            people.append(Person(
                id: canonicalKey,
                name: name,
                aliases: Array(Set(members)).sorted(),
                meetings: personMeetings,
                openTasks: personTasks
            ))
        }

        return people.sorted { lhs, rhs in
            if lhs.meetingCount != rhs.meetingCount { return lhs.meetingCount > rhs.meetingCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Most frequent display spelling of the canonical key, preferring
    /// capitalised forms; falls back to a capitalised key.
    nonisolated static func bestDisplayName(canonicalKey: String, variants: [String: Int]) -> String {
        let candidates = variants.sorted { lhs, rhs in
            let lCap = lhs.key.first?.isUppercase ?? false
            let rCap = rhs.key.first?.isUppercase ?? false
            if lCap != rCap { return lCap }
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        if let best = candidates.first?.key, best.first?.isUppercase == true {
            return best
        }
        return canonicalKey
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Finds a person by key, alias, or (case-insensitive) display name.
    nonisolated static func find(_ query: String, in people: [Person]) -> Person? {
        let key = normalizedKey(query)
        guard !key.isEmpty else { return nil }
        if let exact = people.first(where: { $0.id == key || $0.aliases.contains(key) }) {
            return exact
        }
        // Unique first-name / partial match.
        let partial = people.filter { person in
            containsSequence(nameTokens(person.id), nameTokens(key))
        }
        return partial.count == 1 ? partial.first : nil
    }
}
