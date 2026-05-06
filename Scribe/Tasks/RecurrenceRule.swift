import Foundation

enum RecurrenceError: LocalizedError, Sendable {
    case invalidRule(String)

    var errorDescription: String? {
        if case .invalidRule(let r) = self { return "Invalid recurrence rule: \(r)" }
        return nil
    }
}

struct RecurrenceRule: Equatable, Sendable {

    enum Frequency: String, Sendable {
        case daily   = "DAILY"
        case weekly  = "WEEKLY"
        case monthly = "MONTHLY"
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
    }

    struct OrdinalWeekday: Equatable, Sendable {
        let ordinal: Int    // 1…5 = Nth; -1 = last
        let weekday: Weekday
    }

    let frequency: Frequency
    let interval: Int                       // ≥ 1; default 1
    let byDay: [Weekday]                    // WEEKLY multi-day list
    let byOrdinalWeekday: OrdinalWeekday?   // MONTHLY ordinal weekday

    // MARK: - Serialisation

    var rruleString: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if let ord = byOrdinalWeekday {
            parts.append("BYDAY=\(ord.ordinal)\(ord.weekday.rawValue)")
        } else if !byDay.isEmpty {
            parts.append("BYDAY=\(byDay.map(\.rawValue).joined(separator: ","))")
        }
        return parts.joined(separator: ";")
    }

    // MARK: - Parsing

    private static let ordinalPattern = try! NSRegularExpression(pattern: #"^(-?[1-5])([A-Z]{2})$"#)

    static func parse(_ rrule: String) throws -> RecurrenceRule {
        var pairs: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { pairs[String(kv[0])] = String(kv[1]) }
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
            let nsStr = bydayStr as NSString
            let range = NSRange(location: 0, length: nsStr.length)
            if let match = Self.ordinalPattern.firstMatch(in: bydayStr, range: range) {
                let ordStr = nsStr.substring(with: match.range(at: 1))
                let wdStr  = nsStr.substring(with: match.range(at: 2))
                guard let ordinal = Int(ordStr), let weekday = Weekday(rawValue: wdStr) else {
                    throw RecurrenceError.invalidRule(rrule)
                }
                byOrdinalWeekday = OrdinalWeekday(ordinal: ordinal, weekday: weekday)
            } else {
                for raw in bydayStr.split(separator: ",") {
                    guard let wd = Weekday(rawValue: String(raw)) else {
                        throw RecurrenceError.invalidRule(rrule)
                    }
                    byDay.append(wd)
                }
            }
        }

        return RecurrenceRule(
            frequency: frequency,
            interval: interval,
            byDay: byDay,
            byOrdinalWeekday: byOrdinalWeekday
        )
    }
}
