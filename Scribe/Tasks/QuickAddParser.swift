import Foundation

/// Pure parser for the task list's quick-add field. Lifts inline metadata
/// out of the title so users can type
///
///     buy milk tomorrow 5pm #shopping +Errands !high
///
/// and end up with a task whose title is "buy milk", whose tags include
/// "shopping", whose project hint is "Errands", whose priority is high, and
/// whose `dueAt` is tomorrow at 5pm.
///
/// The parser is intentionally forgiving: anything it can't recognise stays
/// in the title. The store's existing `createTask` validates the rest.
enum QuickAddParser {

    struct ParsedQuickAdd: Equatable {
        var title: String
        var tags: [String]
        var priority: TodoTask.Priority?
        /// Project name as typed (e.g. "Work"). The caller resolves this to
        /// a `Project.id` via `TaskStore.fetchProjects` since we don't want
        /// the parser to touch the database.
        var projectName: String?
        var dueAt: Date?
    }

    static func parse(_ input: String,
                      detector: NSDataDetector? = .scribeDateDetector) -> ParsedQuickAdd {
        var working = input

        // 1) Pull off `#tag`, `+project`, and `!priority` tokens.
        // Two-pass: first scan forward to record matches in source order
        // (preserves first-occurrence ordering for tags), then strip the
        // matched ranges in reverse so earlier ranges stay valid.
        var tags: [String] = []
        var projectName: String?
        var priority: TodoTask.Priority?

        // (?<!\S) = "not preceded by a non-whitespace char" = start-of-string
        // or whitespace boundary. ICU lookbehind succeeds at position 0 when
        // no prior character exists, so this correctly rejects "foo#bar".
        let tokenPattern = #"(?<!\S)([#+!])([A-Za-z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            let nsRange = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = regex.matches(in: working, range: nsRange)
            var rangesToStrip: [Range<String.Index>] = []
            for match in matches {
                guard let prefixRange = Range(match.range(at: 1), in: working),
                      let valueRange = Range(match.range(at: 2), in: working),
                      let fullRange = Range(match.range, in: working) else { continue }
                let prefix = working[prefixRange]
                let value = String(working[valueRange])
                switch prefix {
                case "#":
                    let normalised = value.lowercased()
                    if !tags.contains(normalised) { tags.append(normalised) }
                case "+":
                    if projectName == nil { projectName = value }
                case "!":
                    if priority == nil { priority = mapPriorityToken(value) }
                default:
                    break
                }
                rangesToStrip.append(fullRange)
            }
            for range in rangesToStrip.reversed() {
                working.removeSubrange(range)
            }
        }

        // 2) Look for a date phrase via NSDataDetector. Take the first match;
        // strip its substring out of the title.
        var dueAt: Date?
        if let detector = detector {
            let r = NSRange(working.startIndex..<working.endIndex, in: working)
            if let match = detector.matches(in: working, range: r).first(where: { $0.resultType == .date }),
               let date = match.date,
               let phraseRange = Range(match.range, in: working) {
                dueAt = date
                working.removeSubrange(phraseRange)
            }
        }

        // 3) Whatever's left is the title. Collapse double spaces and trim.
        let title = working
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return ParsedQuickAdd(
            title: title,
            tags: tags,
            priority: priority,
            projectName: projectName,
            dueAt: dueAt
        )
    }

    static func mapPriorityToken(_ token: String) -> TodoTask.Priority? {
        switch token.lowercased() {
        case "high", "h", "1": return .high
        case "med", "medium", "m", "2": return .medium
        case "low", "l", "3": return .low
        default: return nil
        }
    }
}
