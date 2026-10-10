import Foundation

enum RecurrenceError: LocalizedError, Sendable {
    case invalidRule(String)

    var errorDescription: String? {
        if case .invalidRule(let r) = self { return "Invalid recurrence rule: \(r)" }
        return nil
    }
}

/// RRULE-flavoured recurrence rule (an RFC 5545 subset).
///
/// Supported parts:
/// - `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY` (required) and `INTERVAL=n`.
/// - `BYDAY=MO,WE` (weekday list) or `BYDAY=2MO` / `BYDAY=-1FR` (single
///   ordinal weekday, MONTHLY/YEARLY).
/// - `BYMONTHDAY=1,15,-1` (MONTHLY/YEARLY; negative counts from month end).
/// - `BYSETPOS=-1` (MONTHLY/YEARLY; picks from the month's expanded set, e.g.
///   `BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1` = last weekday of the month).
/// - `UNTIL=20261231T235959Z` (or date-only `20261231`, read as the end of
///   that UTC day): occurrences after it end the series.
/// - `COUNT=n`: the number of occurrences *remaining, including the current
///   one*. Scribe stores tasks (not event series), so completing an
///   occurrence decrements COUNT; completing the `COUNT=1` occurrence ends
///   the series.
/// - `X-SCRIBE-FROM=COMPLETION` (Scribe extension): the next occurrence is
///   computed from the completion date instead of the scheduled date
///   ("every 2 weeks after completion").
///
/// Unknown parts are ignored so rules written by other tools still load.
struct RecurrenceRule: Equatable, Sendable {

    enum Frequency: String, Sendable {
        case daily   = "DAILY"
        case weekly  = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly  = "YEARLY"
    }

    enum Weekday: String, CaseIterable, Equatable, Sendable {
        case mo = "MO", tu = "TU", we = "WE", th = "TH"
        case fr = "FR", sa = "SA", su = "SU"

        /// Gregorian weekday number (Sunday = 1 … Saturday = 7).
        var calendarWeekday: Int {
            switch self {
            case .su: return 1
            case .mo: return 2
            case .tu: return 3
            case .we: return 4
            case .th: return 5
            case .fr: return 6
            case .sa: return 7
            }
        }

        static let weekdays: [Weekday] = [.mo, .tu, .we, .th, .fr]

        /// Inverse of `calendarWeekday`.
        static func from(calendarWeekday value: Int) -> Weekday? {
            allCases.first { $0.calendarWeekday == value }
        }
    }

    struct OrdinalWeekday: Equatable, Sendable {
        let ordinal: Int    // 1…5 = Nth; -1 = last
        let weekday: Weekday
    }

    var frequency: Frequency
    var interval: Int                       // ≥ 1; default 1
    var byDay: [Weekday]                    // weekday list
    var byOrdinalWeekday: OrdinalWeekday?   // MONTHLY ordinal weekday
    var byMonthDay: [Int]                   // ±1…31
    var bySetPos: [Int]                     // ±1…366
    var until: Date?
    /// Remaining occurrences including the current one (see type docs).
    var count: Int?
    /// `X-SCRIBE-FROM=COMPLETION`: schedule from the completion date.
    var fromCompletion: Bool

    init(
        frequency: Frequency,
        interval: Int = 1,
        byDay: [Weekday] = [],
        byOrdinalWeekday: OrdinalWeekday? = nil,
        byMonthDay: [Int] = [],
        bySetPos: [Int] = [],
        until: Date? = nil,
        count: Int? = nil,
        fromCompletion: Bool = false
    ) {
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.byOrdinalWeekday = byOrdinalWeekday
        self.byMonthDay = byMonthDay
        self.bySetPos = bySetPos
        self.until = until
        self.count = count
        self.fromCompletion = fromCompletion
    }

    static let fromCompletionKey = "X-SCRIBE-FROM"
    static let fromCompletionValue = "COMPLETION"

    // MARK: - Serialisation

    var rruleString: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if let ord = byOrdinalWeekday {
            parts.append("BYDAY=\(ord.ordinal)\(ord.weekday.rawValue)")
        } else if !byDay.isEmpty {
            parts.append("BYDAY=\(byDay.map(\.rawValue).joined(separator: ","))")
        }
        if !byMonthDay.isEmpty {
            parts.append("BYMONTHDAY=\(byMonthDay.map(String.init).joined(separator: ","))")
        }
        if !bySetPos.isEmpty {
            parts.append("BYSETPOS=\(bySetPos.map(String.init).joined(separator: ","))")
        }
        if let count { parts.append("COUNT=\(count)") }
        if let until { parts.append("UNTIL=\(Self.formatUntil(until))") }
        if fromCompletion { parts.append("\(Self.fromCompletionKey)=\(Self.fromCompletionValue)") }
        return parts.joined(separator: ";")
    }

    // MARK: - Parsing

    static func parse(_ rrule: String) throws -> RecurrenceRule {
        var pairs: [String: String] = [:]
        // Tolerate an "RRULE:" prefix as written by calendar exports.
        var body = rrule.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("RRULE:") { body = String(body.dropFirst(6)) }
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                pairs[String(kv[0]).uppercased()] = String(kv[1]).uppercased()
            }
        }

        guard let freqStr = pairs["FREQ"],
              let frequency = Frequency(rawValue: freqStr) else {
            throw RecurrenceError.invalidRule(rrule)
        }

        let interval: Int
        if let raw = pairs["INTERVAL"] {
            guard let i = Int(raw), i > 0 else { throw RecurrenceError.invalidRule(rrule) }
            interval = i
        } else {
            interval = 1
        }

        var byDay: [Weekday] = []
        var byOrdinalWeekday: OrdinalWeekday? = nil

        if let bydayStr = pairs["BYDAY"] {
            if let ordinal = parseOrdinalWeekday(bydayStr) {
                byOrdinalWeekday = ordinal
            } else {
                for raw in bydayStr.split(separator: ",") {
                    guard let wd = Weekday(rawValue: String(raw)) else {
                        throw RecurrenceError.invalidRule(rrule)
                    }
                    if !byDay.contains(wd) { byDay.append(wd) }
                }
                if byDay.isEmpty { throw RecurrenceError.invalidRule(rrule) }
            }
        }

        var byMonthDay: [Int] = []
        if let raw = pairs["BYMONTHDAY"] {
            guard let values = parseIntList(raw, range: 1...31) else {
                throw RecurrenceError.invalidRule(rrule)
            }
            byMonthDay = values
        }

        var bySetPos: [Int] = []
        if let raw = pairs["BYSETPOS"] {
            guard let values = parseIntList(raw, range: 1...366) else {
                throw RecurrenceError.invalidRule(rrule)
            }
            bySetPos = values
        }

        var count: Int?
        if let raw = pairs["COUNT"] {
            guard let c = Int(raw), c > 0 else { throw RecurrenceError.invalidRule(rrule) }
            count = c
        }

        var until: Date?
        if let raw = pairs["UNTIL"] {
            guard let date = parseUntil(raw) else { throw RecurrenceError.invalidRule(rrule) }
            until = date
        }

        // Normalise combinations RFC 5545 disallows instead of throwing:
        // rules stored before these parts were understood (when unknown parts
        // were ignored) must keep parsing, or their tasks couldn't complete.
        // - COUNT and UNTIL are mutually exclusive: UNTIL wins.
        if until != nil { count = nil }
        switch frequency {
        case .daily, .weekly:
            // Month-scoped parts only make sense for MONTHLY / YEARLY.
            byMonthDay = []
            bySetPos = []
            byOrdinalWeekday = nil
        case .monthly, .yearly:
            // BYSETPOS selects from an expanded set — without one it's moot.
            if byDay.isEmpty && byMonthDay.isEmpty && byOrdinalWeekday == nil {
                bySetPos = []
            }
        }

        let fromCompletion = pairs[fromCompletionKey] == fromCompletionValue

        return RecurrenceRule(
            frequency: frequency,
            interval: interval,
            byDay: byDay,
            byOrdinalWeekday: byOrdinalWeekday,
            byMonthDay: byMonthDay,
            bySetPos: bySetPos,
            until: until,
            count: count,
            fromCompletion: fromCompletion
        )
    }

    /// Parses a single `[-]NWD` ordinal weekday (e.g. `2MO`, `-1FR`). Returns
    /// nil for anything else (plain weekday lists are handled by the caller).
    private static func parseOrdinalWeekday(_ raw: String) -> OrdinalWeekday? {
        guard raw.count >= 3, !raw.contains(",") else { return nil }
        let code = String(raw.suffix(2))
        let number = String(raw.dropLast(2))
        guard let weekday = Weekday(rawValue: code),
              let ordinal = Int(number),
              (1...5).contains(abs(ordinal)) else { return nil }
        return OrdinalWeekday(ordinal: ordinal, weekday: weekday)
    }

    /// Parses a comma list of non-zero integers whose magnitude is in `range`.
    private static func parseIntList(_ raw: String, range: ClosedRange<Int>) -> [Int]? {
        var out: [Int] = []
        for piece in raw.split(separator: ",") {
            guard let value = Int(piece), value != 0, range.contains(abs(value)) else { return nil }
            if !out.contains(value) { out.append(value) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - UNTIL (UTC, no DateFormatter so the type stays Sendable-clean)

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC.
    static func formatUntil(_ date: Date) -> String {
        let c = Calendar.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "T"
            + pad(c.hour, 2) + pad(c.minute, 2) + pad(c.second, 2) + "Z"
    }

    /// Accepts `yyyyMMdd` (end of that UTC day) or `yyyyMMddTHHmmss[Z]` (UTC).
    static func parseUntil(_ raw: String) -> Date? {
        let chars = Array(raw)
        func int(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= chars.count else { return nil }
            return Int(String(chars[from..<(from + len)]))
        }
        guard chars.count >= 8, let y = int(0, 4), let mo = int(4, 2), let d = int(6, 2) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        if chars.count == 8 {
            comps.hour = 23; comps.minute = 59; comps.second = 59
        } else {
            guard chars.count >= 15, chars[8] == "T",
                  let h = int(9, 2), let mi = int(11, 2), let s = int(13, 2) else { return nil }
            if chars.count > 15 && !(chars.count == 16 && chars[15] == "Z") { return nil }
            comps.hour = h; comps.minute = mi; comps.second = s
        }
        guard (1...12).contains(mo), (1...31).contains(d) else { return nil }
        return Calendar.utcCalendar.date(from: comps)
    }

    // MARK: - Description

    /// Short human summary for the task inspector, e.g. "Every 2 weeks on
    /// Mon, Fri · after completion".
    var summary: String {
        var text: String
        let unit: String
        switch frequency {
        case .daily:   unit = "day"
        case .weekly:  unit = "week"
        case .monthly: unit = "month"
        case .yearly:  unit = "year"
        }
        text = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
        if Set(byDay) == Set(Weekday.weekdays) && byDay.count == 5 && bySetPos.isEmpty {
            text += " on weekdays"
        } else if !byDay.isEmpty && bySetPos.isEmpty {
            text += " on " + byDay.map(Self.shortName).joined(separator: ", ")
        }
        if let ord = byOrdinalWeekday {
            text += " on the \(Self.ordinalName(ord.ordinal)) \(Self.shortName(ord.weekday))"
        }
        if !bySetPos.isEmpty, !byDay.isEmpty {
            let what = Set(byDay) == Set(Weekday.weekdays) && byDay.count == 5
                ? "weekday" : byDay.map(Self.shortName).joined(separator: "/")
            text += " on the " + bySetPos.map(Self.ordinalName).joined(separator: ", ") + " \(what)"
        }
        if !byMonthDay.isEmpty {
            text += " on day " + byMonthDay.map { $0 == -1 ? "last" : String($0) }.joined(separator: ", ")
        }
        if fromCompletion { text += " · after completion" }
        if let count { text += " · \(count) left" }
        if let until { text += " · until \(until.formatted(date: .abbreviated, time: .omitted))" }
        return text
    }

    private static func shortName(_ day: Weekday) -> String {
        switch day {
        case .mo: return "Mon"
        case .tu: return "Tue"
        case .we: return "Wed"
        case .th: return "Thu"
        case .fr: return "Fri"
        case .sa: return "Sat"
        case .su: return "Sun"
        }
    }

    private static func ordinalName(_ n: Int) -> String {
        switch n {
        case -1: return "last"
        case -2: return "second-to-last"
        case 1:  return "1st"
        case 2:  return "2nd"
        case 3:  return "3rd"
        default: return "\(n)th"
        }
    }
}
