import Foundation

/// Pure parser for the task list's quick-add field. Lifts inline metadata
/// out of the title so users can type
///
///     buy milk tmr 5pm #shopping +Errands !high
///
/// and end up with a task whose title is "buy milk", whose tags include
/// "shopping", whose project hint is "Errands", whose priority is high, and
/// whose `dueAt` is tomorrow at 5pm.
///
/// Short-form date abbreviations are expanded before NLP detection:
/// "tmr/tmrw/tom" → "tomorrow", "next mon" → "next monday", etc.
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

    // MARK: - Token ranges (for live highlighting)

    enum TokenKind { case date, tag, project, priority }

    struct TokenRange {
        let kind: TokenKind
        let range: Range<String.Index>
    }

    /// Returns the ranges (and kinds) of all recognised tokens in `input`,
    /// without mutating the string. Used by the highlighting text field.
    static func tokenRanges(in input: String,
                            detector: NSDataDetector? = .scribeDateDetector) -> [TokenRange] {
        var result: [TokenRange] = []

        // #tag, +project, !priority
        let tokenPattern = #"(?<!\S)([#+!])([A-Za-z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
            for match in regex.matches(in: input, range: nsRange) {
                guard let prefixRange = Range(match.range(at: 1), in: input),
                      let fullRange   = Range(match.range, in: input) else { continue }
                let prefix = String(input[prefixRange])
                let kind: TokenKind
                switch prefix {
                case "#": kind = .tag
                case "+": kind = .project
                case "!": kind = .priority
                default:  continue
                }
                result.append(TokenRange(kind: kind, range: fullRange))
            }
        }

        // Natural-language dates via NSDataDetector (handles "tomorrow", "friday", etc.)
        if let detector = detector {
            let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
            for match in detector.matches(in: input, range: nsRange) where match.resultType == .date {
                if let range = Range(match.range, in: input) {
                    result.append(TokenRange(kind: .date, range: range))
                }
            }
        }

        // Short-form abbreviations that NSDataDetector won't recognise
        for (regex, _) in shortForms {
            let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
            for match in regex.matches(in: input, options: [], range: nsRange) {
                guard let range = Range(match.range, in: input) else { continue }
                let alreadyCovered = result.contains { $0.kind == .date && $0.range.overlaps(range) }
                if !alreadyCovered {
                    result.append(TokenRange(kind: .date, range: range))
                }
            }
        }

        return result
    }

    // MARK: - Short-form expansion

    /// Ordered substitution table.  More-specific multi-word patterns (e.g.
    /// "next mon") appear before single-word ones ("mon") so they match first.
    private static let shortForms: [(regex: NSRegularExpression, replacement: String)] = {
        let pairs: [(String, String)] = [
            // "tomorrow" short forms
            (#"\btmr(w)?\b"#,          "tomorrow"),
            (#"\btom\b"#,              "tomorrow"),
            // "today" short forms
            (#"\btdy\b"#,              "today"),
            // "next <day>" short forms – multi-word, must come before single-word
            (#"\bnext\s+mon\b"#,       "next monday"),
            (#"\bnext\s+tue(s)?\b"#,   "next tuesday"),
            (#"\bnext\s+wed\b"#,       "next wednesday"),
            (#"\bnext\s+thu(rs?)?\b"#, "next thursday"),
            (#"\bnext\s+fri\b"#,       "next friday"),
            (#"\bnext\s+sat\b"#,       "next saturday"),
            (#"\bnext\s+sun\b"#,       "next sunday"),
            (#"\bnext\s+wk\b"#,        "next week"),
            // standalone abbreviated day names (only when NOT preceded by "next ")
            (#"(?<!next )\bmon\b"#,    "this monday"),
            (#"(?<!next )\btue\b"#,    "this tuesday"),
            (#"(?<!next )\bwed\b"#,    "this wednesday"),
            (#"(?<!next )\bthu\b"#,    "this thursday"),
            (#"(?<!next )\bfri\b"#,    "this friday"),
            (#"(?<!next )\bsat\b"#,    "this saturday"),
            (#"(?<!next )\bsun\b"#,    "this sunday"),
        ]
        return pairs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                        options: .caseInsensitive)
            else { return nil }
            return (regex, replacement)
        }
    }()

    /// Returns `input` with all short-form date abbreviations replaced by
    /// their full equivalents so `NSDataDetector` can parse them.
    static func expandShortForms(_ input: String) -> String {
        var result = input
        for (regex, replacement) in shortForms {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result,
                                                    options: [],
                                                    range: nsRange,
                                                    withTemplate: replacement)
        }
        return result
    }

    // MARK: - Full parse

    static func parse(_ input: String,
                      detector: NSDataDetector? = .scribeDateDetector) -> ParsedQuickAdd {
        var working = input

        // 1) Pull off `#tag`, `+project`, and `!priority` tokens.
        var tags: [String] = []
        var projectName: String?
        var priority: TodoTask.Priority?

        let tokenPattern = #"(?<!\S)([#+!])([A-Za-z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            let nsRange = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = regex.matches(in: working, range: nsRange)
            var rangesToStrip: [Range<String.Index>] = []
            for match in matches {
                guard let prefixRange = Range(match.range(at: 1), in: working),
                      let valueRange  = Range(match.range(at: 2), in: working),
                      let fullRange   = Range(match.range, in: working) else { continue }
                let prefix = working[prefixRange]
                let value  = String(working[valueRange])
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

        // 2) Expand short-form abbreviations so NSDataDetector can parse them,
        //    then look for a date phrase. Strip it from the working title.
        let expanded = Self.expandShortForms(working)
        var dueAt: Date?
        if let detector = detector {
            let r = NSRange(expanded.startIndex..<expanded.endIndex, in: expanded)
            if let match = detector.matches(in: expanded, range: r).first(where: { $0.resultType == .date }),
               let date = match.date,
               let phraseRange = Range(match.range, in: expanded) {
                dueAt = date
                var stripped = expanded
                stripped.removeSubrange(phraseRange)
                working = stripped
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
