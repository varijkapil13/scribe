import Foundation

/// Planning metadata lifted out of a quick-add title by
/// `QuickAddPlanningParser` (recurrence, start date, when-bucket, duration).
struct QuickAddPlanning: Equatable, Sendable {
    var recurrence: RecurrenceRule?
    var startAt: Date?
    var scheduleBucket: TaskScheduleBucket?
    var estimatedMinutes: Int?
}

/// Pure, deterministic parser for the planning phrases the quick-add field
/// understands (on top of `QuickAddParser`'s `#tag +Project !priority` and
/// natural-language due dates):
///
/// - Recurrence: "every day", "every other week", "every 2 weeks",
///   "every month", "every year", "every weekday", "every mon, wed and fri",
///   "every last weekday (of the month)", "every 2nd tuesday",
///   "every last day of the month"; modifiers (only after a recurrence)
///   "after completion", "until Dec 31", "for 5 times".
/// - Start / defer date: "starting friday", "starting tomorrow",
///   "starts on Mar 3", "beginning next week".
/// - When-bucket: "someday", "this evening" / "tonight".
/// - Duration: "~30m", "~1h30m", "~2 hours", "for 1h", "for 45 min".
///
/// Date phrases it resolves itself (no `NSDataDetector`, so results are
/// reproducible with an injected `now`): today, tomorrow/tmr/tmrw, next week,
/// next month, in N days/weeks/months, weekday names (optionally prefixed
/// with this/next — always the first such day *after* today), "Dec 31"
/// / "December 31st, 2027", and ISO `2026-12-31`.
///
/// Recognised phrases are removed from the text (replaced by a space); the
/// caller collapses whitespace. Regexes are built per call — the parser runs
/// once per keystroke at most, and this keeps the type free of shared mutable
/// or non-Sendable statics.
enum QuickAddPlanningParser {

    // MARK: - Patterns

    static let weekdayPattern =
        #"(?:mon|tues|tue|wed|thurs|thur|thu|fri|sat|sun)(?:day|sday|nesday|rsday|urday)?"#
    static let monthPattern =
        #"(?:jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\.?"#
    static var datePattern: String {
        "(?:today|tomorrow|tmrw|tmr|next\\s+week|next\\s+month"
            + "|in\\s+\\d+\\s+(?:days?|weeks?|months?)"
            + "|\\d{4}-\\d{1,2}-\\d{1,2}"
            + "|\(monthPattern)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s+\\d{4})?"
            + "|(?:next\\s+|this\\s+)?\(weekdayPattern))"
    }

    private static var ordinalRecurrencePattern: String {
        #"\bevery\s+(first|1st|second|2nd|third|3rd|fourth|4th|last)\s+(weekday|day|"#
            + weekdayPattern
            + #")(?:\s+of\s+(?:the|each|every)\s+month)?\b"#
    }
    private static let weekdaysRecurrencePattern = #"\bevery\s+weekday\b"#
    private static var weekdayListRecurrencePattern: String {
        #"\bevery\s+("# + weekdayPattern + #"(?:\s*(?:,|and|&)\s*"# + weekdayPattern + #")*)\b"#
    }
    private static let intervalRecurrencePattern =
        #"\bevery\s+(?:(other)\s+|(\d+)\s+)?(day|week|month|year)s?\b"#
    private static let fromCompletionPattern =
        #"\b(?:after|from)\s+(?:completion|completing|complete|completed|done|finishing)\b"#
    private static var untilPattern: String { #"\buntil\s+("# + datePattern + #")\b"# }
    private static let countPattern = #"\b(?:for\s+)?(\d+)\s+times\b"#
    private static var startPattern: String {
        #"\b(?:starting(?:\s+on)?|starts(?:\s+on)?|start\s+on|beginning)\s+("# + datePattern + #")\b"#
    }
    private static let somedayPattern = #"\bsomeday\b"#
    private static let eveningPattern = #"\b(?:this\s+evening|tonight)\b"#
    private static let hoursDurationPattern =
        #"(?:(?<!\S)~\s*|\bfor\s+)(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)(?:\s*(\d+)\s*(?:m|min|mins|minute|minutes))?\b"#
    private static let minutesDurationPattern =
        #"(?:(?<!\S)~\s*|\bfor\s+)(\d+)\s*(?:m|min|mins|minute|minutes)\b"#

    // MARK: - Extraction

    /// Removes every recognised planning phrase from `text` and returns what
    /// it found.
    static func extract(from text: inout String, now: Date, calendar: Calendar) -> QuickAddPlanning {
        var result = QuickAddPlanning()

        // 1) Recurrence + its modifiers (modifiers only count after "every …").
        if var rule = extractRecurrence(from: &text) {
            if take(fromCompletionPattern, from: &text) != nil {
                rule.fromCompletion = true
            }
            if let groups = take(untilPattern, from: &text),
               let phrase = groups.first ?? nil,
               let day = resolveDate(phrase, now: now, calendar: calendar),
               let nextDay = calendar.date(byAdding: .day, value: 1, to: day) {
                // Inclusive: the whole until-day counts.
                rule.until = nextDay.addingTimeInterval(-1)
            }
            if rule.until == nil,
               let groups = take(countPattern, from: &text),
               let raw = groups.first ?? nil,
               let count = Int(raw), count > 0 {
                rule.count = count
            }
            result.recurrence = rule
        }

        // 2) Start / defer date.
        if let groups = take(startPattern, from: &text),
           let phrase = groups.first ?? nil {
            result.startAt = resolveDate(phrase, now: now, calendar: calendar)
        }

        // 3) When-bucket.
        if take(somedayPattern, from: &text) != nil {
            result.scheduleBucket = .someday
        } else if take(eveningPattern, from: &text) != nil {
            result.scheduleBucket = .evening
        }

        // 4) Duration.
        if let groups = take(hoursDurationPattern, from: &text),
           let hoursRaw = groups.first ?? nil,
           let hours = Double(hoursRaw) {
            let extra = groups.count > 1 ? (groups[1].flatMap { Int($0) } ?? 0) : 0
            result.estimatedMinutes = Int((hours * 60).rounded()) + extra
        } else if let groups = take(minutesDurationPattern, from: &text),
                  let raw = groups.first ?? nil,
                  let minutes = Int(raw) {
            result.estimatedMinutes = minutes
        }

        return result
    }

    /// Ranges of every planning phrase in `text` (for live highlighting).
    /// Non-destructive; may report modifiers even without a recurrence.
    static func ranges(in text: String) -> [Range<String.Index>] {
        let patterns = [
            ordinalRecurrencePattern, weekdaysRecurrencePattern, weekdayListRecurrencePattern,
            intervalRecurrencePattern, fromCompletionPattern, untilPattern, countPattern,
            startPattern, somedayPattern, eveningPattern, hoursDurationPattern, minutesDurationPattern,
        ]
        var out: [Range<String.Index>] = []
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = makeRegex(pattern) else { continue }
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text),
                      !out.contains(where: { $0.overlaps(range) }) else { continue }
                out.append(range)
            }
        }
        return out
    }

    // MARK: - Recurrence phrases

    private static func extractRecurrence(from text: inout String) -> RecurrenceRule? {
        if let groups = take(ordinalRecurrencePattern, from: &text),
           groups.count >= 2,
           let ordinalWord = groups[0], let what = groups[1],
           let ordinal = ordinalValue(ordinalWord) {
            let lowered = what.lowercased()
            if lowered == "weekday" {
                return RecurrenceRule(frequency: .monthly, byDay: RecurrenceRule.Weekday.weekdays,
                                      bySetPos: [ordinal])
            }
            if lowered == "day" {
                return RecurrenceRule(frequency: .monthly, byMonthDay: [ordinal])
            }
            if let weekday = weekday(from: lowered) {
                return RecurrenceRule(frequency: .monthly,
                                      byOrdinalWeekday: .init(ordinal: ordinal, weekday: weekday))
            }
        }
        if take(weekdaysRecurrencePattern, from: &text) != nil {
            return RecurrenceRule(frequency: .weekly, byDay: RecurrenceRule.Weekday.weekdays)
        }
        if let groups = take(weekdayListRecurrencePattern, from: &text),
           let list = groups.first ?? nil {
            var days: [RecurrenceRule.Weekday] = []
            if let regex = makeRegex(weekdayPattern) {
                let range = NSRange(list.startIndex..<list.endIndex, in: list)
                for match in regex.matches(in: list, range: range) {
                    guard let r = Range(match.range, in: list),
                          let day = weekday(from: String(list[r]).lowercased()),
                          !days.contains(day) else { continue }
                    days.append(day)
                }
            }
            if !days.isEmpty {
                days.sort { order(of: $0) < order(of: $1) }
                return RecurrenceRule(frequency: .weekly, byDay: days)
            }
        }
        if let groups = take(intervalRecurrencePattern, from: &text), groups.count >= 3,
           let unit = groups[2] {
            var interval = 1
            if groups[0] != nil { interval = 2 }
            if let raw = groups[1], let n = Int(raw), n > 0 { interval = n }
            let frequency: RecurrenceRule.Frequency
            switch unit.lowercased() {
            case "day":   frequency = .daily
            case "week":  frequency = .weekly
            case "month": frequency = .monthly
            default:      frequency = .yearly
            }
            return RecurrenceRule(frequency: frequency, interval: interval)
        }
        return nil
    }

    private static func ordinalValue(_ word: String) -> Int? {
        switch word.lowercased() {
        case "first", "1st":  return 1
        case "second", "2nd": return 2
        case "third", "3rd":  return 3
        case "fourth", "4th": return 4
        case "last":          return -1
        default:              return nil
        }
    }

    /// Weekday from a (lowercased) name or abbreviation.
    static func weekday(from name: String) -> RecurrenceRule.Weekday? {
        switch String(name.prefix(3)) {
        case "mon": return .mo
        case "tue": return .tu
        case "wed": return .we
        case "thu": return .th
        case "fri": return .fr
        case "sat": return .sa
        case "sun": return .su
        default:    return nil
        }
    }

    /// Monday-first ordering for a readable BYDAY list.
    private static func order(of day: RecurrenceRule.Weekday) -> Int {
        (day.calendarWeekday + 5) % 7
    }

    // MARK: - Date phrases

    /// Resolves a date phrase (see `datePattern`) to the start of that day in
    /// `calendar`, or nil when it isn't one this parser understands.
    static func resolveDate(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        let lowered = phrase.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let today = calendar.startOfDay(for: now)

        switch lowered {
        case "today":                    return today
        case "tomorrow", "tmr", "tmrw":  return calendar.date(byAdding: .day, value: 1, to: today)
        case "next week":                return calendar.date(byAdding: .day, value: 7, to: today)
        case "next month":               return calendar.date(byAdding: .month, value: 1, to: today)
        default: break
        }

        let words = lowered.split(separator: " ").map(String.init)

        // in N days / weeks / months
        if words.count == 3, words[0] == "in", let n = Int(words[1]) {
            if words[2].hasPrefix("day") { return calendar.date(byAdding: .day, value: n, to: today) }
            if words[2].hasPrefix("week") { return calendar.date(byAdding: .day, value: 7 * n, to: today) }
            if words[2].hasPrefix("month") { return calendar.date(byAdding: .month, value: n, to: today) }
            return nil
        }

        // ISO yyyy-mm-dd
        let isoParts = lowered.split(separator: "-")
        if isoParts.count == 3, let y = Int(isoParts[0]), let m = Int(isoParts[1]), let d = Int(isoParts[2]) {
            return validDate(year: y, month: m, day: d, calendar: calendar)
        }

        // Weekday (optionally "this"/"next"): the first such day after today.
        var weekdayWord = lowered
        if words.count == 2, words[0] == "next" || words[0] == "this" { weekdayWord = words[1] }
        if !weekdayWord.contains(" "), let day = weekday(from: weekdayWord),
           weekdayWord.count >= 3, isWeekdayName(weekdayWord) {
            let current = calendar.component(.weekday, from: today)
            var ahead = (day.calendarWeekday - current + 7) % 7
            if ahead == 0 { ahead = 7 }
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }

        // Month name + day (+ optional year).
        if words.count >= 2, let month = monthNumber(words[0]) {
            let dayDigits = words[1].prefix { $0.isNumber }
            guard let day = Int(dayDigits) else { return nil }
            if words.count >= 3, let year = Int(words[2]) {
                return validDate(year: year, month: month, day: day, calendar: calendar)
            }
            let thisYear = calendar.component(.year, from: today)
            guard let candidate = validDate(year: thisYear, month: month, day: day, calendar: calendar) else {
                return nil
            }
            // A bare "Dec 31" means the next one on or after today.
            if candidate < today {
                return validDate(year: thisYear + 1, month: month, day: day, calendar: calendar)
            }
            return candidate
        }
        return nil
    }

    private static func isWeekdayName(_ word: String) -> Bool {
        guard let regex = makeRegex("^" + weekdayPattern + "$") else { return false }
        return regex.firstMatch(in: word, range: NSRange(word.startIndex..<word.endIndex, in: word)) != nil
    }

    private static func monthNumber(_ word: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let key = String(word.trimmingCharacters(in: CharacterSet(charactersIn: ".,")).prefix(3))
        guard let index = names.firstIndex(of: key) else { return nil }
        return index + 1
    }

    /// Start of the given day, or nil when the components don't name a real
    /// date (e.g. Feb 30 — `Calendar` would otherwise roll it over).
    private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    // MARK: - Regex helpers

    private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Finds the first match of `pattern`, removes it from `text` (replacing
    /// it with a space) and returns its capture groups (nil per group that
    /// didn't participate). Returns nil when there is no match.
    private static func take(_ pattern: String, from text: inout String) -> [String?]? {
        guard let regex = makeRegex(pattern) else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: whole),
              let fullRange = Range(match.range, in: text) else { return nil }
        var groups: [String?] = []
        if match.numberOfRanges > 1 {
            for index in 1..<match.numberOfRanges {
                if let r = Range(match.range(at: index), in: text) {
                    groups.append(String(text[r]))
                } else {
                    groups.append(nil)
                }
            }
        }
        text.replaceSubrange(fullRange, with: " ")
        return groups
    }
}
