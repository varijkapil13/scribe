import Foundation

/// A parsed `scribe://` URL — the app's public automation surface (Shortcuts,
/// Raycast/Alfred, `open scribe://…` in a script, links pasted into other
/// apps, "Copy Link" on a note).
///
/// Supported forms:
///
///     scribe://note/<id>                    open a note
///     scribe://note?title=<title>           open a note by (case-insensitive) title
///     scribe://new-note?title=&body=        create a note (both optional)
///     scribe://task/<id>                    open a task
///     scribe://new-task?title=&due=         create a task (title required)
///     scribe://meeting/<sessionId>          open a recording's transcript
///     scribe://record/start                 start recording
///     scribe://record/stop                  stop recording
///     scribe://dictate                      toggle dictation
///     scribe://search?q=<query>             open the command bar with a query
///     scribe://today                        go to Today
///
/// Pure value type: parsing and URL building never touch app state, so the
/// grammar is unit-tested in isolation (`ScribeDeepLinkTests`). The routing
/// side lives in `ScribeEntryRouter`.
enum ScribeDeepLink: Equatable, Sendable {
    case note(id: String)
    case noteByTitle(String)
    case newNote(title: String?, body: String?)
    case task(id: String)
    case newTask(title: String, due: String?)
    case meeting(sessionId: String)
    case startRecording
    case stopRecording
    case dictate
    case search(query: String)
    case today

    static let scheme = "scribe"

    // MARK: - Parsing

    /// Parses `url`, returning nil for any other scheme, an unknown route, or
    /// a route missing a required part (e.g. `scribe://note/` with no id).
    ///
    /// Accepts both `scribe://note/<id>` (route in the host) and
    /// `scribe:///note/<id>` / `scribe:note/<id>` (route in the path). Route
    /// names are case-insensitive; ids are kept verbatim. Query values are
    /// decoded with form semantics (`+` is a space, `%2B` a literal plus).
    nonisolated static func parse(_ url: URL) -> ScribeDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme else { return nil }

        var segments: [String] = []
        if let host = components.host, !host.isEmpty {
            segments.append(host)
        }
        // Split the *encoded* path so an id containing an encoded `/` stays
        // one segment, then decode each segment.
        segments += components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        guard let first = segments.first else { return nil }

        let route = first.lowercased()
        let rest = Array(segments.dropFirst())
        let query = queryDictionary(components)

        switch route {
        case "note":
            if let id = singleId(rest) { return .note(id: id) }
            guard rest.isEmpty else { return nil }
            if let id = nonEmpty(query["id"]) { return .note(id: id) }
            if let title = nonEmpty(query["title"]) { return .noteByTitle(title) }
            return nil

        case "new-note", "newnote":
            guard rest.isEmpty else { return nil }
            return .newNote(title: nonEmpty(query["title"]), body: nonEmptyBody(query["body"]))

        case "task":
            if let id = singleId(rest) { return .task(id: id) }
            guard rest.isEmpty, let id = nonEmpty(query["id"]) else { return nil }
            return .task(id: id)

        case "new-task", "newtask":
            guard rest.isEmpty, let title = nonEmpty(query["title"]) else { return nil }
            return .newTask(title: title, due: nonEmpty(query["due"]))

        case "meeting", "session", "recording":
            if let id = singleId(rest) { return .meeting(sessionId: id) }
            guard rest.isEmpty, let id = nonEmpty(query["id"]) else { return nil }
            return .meeting(sessionId: id)

        case "record":
            guard rest.count == 1 else { return nil }
            switch rest[0].lowercased() {
            case "start": return .startRecording
            case "stop":  return .stopRecording
            default:      return nil
            }

        case "dictate", "dictation":
            guard rest.isEmpty else { return nil }
            return .dictate

        case "search":
            guard rest.isEmpty else { return nil }
            let raw = query["q"] ?? query["query"] ?? ""
            return .search(query: raw.trimmingCharacters(in: .whitespacesAndNewlines))

        case "today":
            guard rest.isEmpty else { return nil }
            return .today

        default:
            return nil
        }
    }

    // MARK: - Building

    /// The canonical URL for this link (what "Copy Link" puts on the
    /// pasteboard). `parse(url)` round-trips it.
    nonisolated var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        var items: [URLQueryItem] = []
        switch self {
        case .note(let id):
            components.host = "note"
            components.percentEncodedPath = "/" + Self.formEncode(id)
        case .noteByTitle(let title):
            components.host = "note"
            items = [URLQueryItem(name: "title", value: title)]
        case .newNote(let title, let body):
            components.host = "new-note"
            if let title { items.append(URLQueryItem(name: "title", value: title)) }
            if let body { items.append(URLQueryItem(name: "body", value: body)) }
        case .task(let id):
            components.host = "task"
            components.percentEncodedPath = "/" + Self.formEncode(id)
        case .newTask(let title, let due):
            components.host = "new-task"
            items.append(URLQueryItem(name: "title", value: title))
            if let due { items.append(URLQueryItem(name: "due", value: due)) }
        case .meeting(let sessionId):
            components.host = "meeting"
            components.percentEncodedPath = "/" + Self.formEncode(sessionId)
        case .startRecording:
            components.host = "record"
            components.path = "/start"
        case .stopRecording:
            components.host = "record"
            components.path = "/stop"
        case .dictate:
            components.host = "dictate"
        case .search(let query):
            components.host = "search"
            items = [URLQueryItem(name: "q", value: query)]
        case .today:
            components.host = "today"
        }
        if !items.isEmpty {
            // Encode with form semantics so `parse` (which reads `+` as a
            // space) round-trips values containing a literal `+`, `&` or `=`.
            components.percentEncodedQuery = items
                .map { "\(Self.formEncode($0.name))=\(Self.formEncode($0.value ?? ""))" }
                .joined(separator: "&")
        }
        return components.url
    }

    /// `scribe://note/<id>` — the link "Copy Link" writes for a note.
    nonisolated static func noteURL(id: String) -> URL? {
        ScribeDeepLink.note(id: id).url
    }

    // MARK: - Due dates

    /// Interprets a `new-task` `due=` value without natural-language guessing:
    /// `today`, `tomorrow`, a calendar date `YYYY-MM-DD` (start of that day
    /// in `calendar`'s time zone) or an ISO-8601 date-time with a zone
    /// (`2026-10-10T17:00:00Z`, `…+02:00`). Anything else returns nil — the
    /// router then falls back to the quick-add natural-language parser.
    nonisolated static func dueDate(from raw: String, now: Date, calendar: Calendar) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "today":
            return calendar.startOfDay(for: now)
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        default:
            break
        }
        if let day = calendarDay(value, calendar: calendar) {
            return day
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }

    // MARK: - Helpers

    /// `YYYY-MM-DD` → start of that day, rejecting impossible dates
    /// (`2026-02-31`) instead of letting `Calendar` roll them over.
    nonisolated private static func calendarDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// Exactly one non-blank path segment → that segment (trimmed).
    nonisolated private static func singleId(_ rest: [String]) -> String? {
        guard rest.count == 1 else { return nil }
        return nonEmpty(rest[0])
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Bodies keep their inner whitespace/newlines; only an all-blank body
    /// counts as absent.
    nonisolated private static func nonEmptyBody(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Query items decoded with `application/x-www-form-urlencoded`
    /// semantics. Keys are lower-cased; the first occurrence of a key wins.
    nonisolated private static func queryDictionary(_ components: URLComponents) -> [String: String] {
        var out: [String: String] = [:]
        for item in components.percentEncodedQueryItems ?? [] {
            let name = formDecode(item.name).lowercased()
            guard out[name] == nil else { continue }
            out[name] = formDecode(item.value ?? "")
        }
        return out
    }

    nonisolated private static func formDecode(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Percent-encodes everything except the RFC 3986 unreserved ASCII set,
    /// so the result is valid in a path segment and in a form query value.
    nonisolated private static func formEncode(_ raw: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }
}
