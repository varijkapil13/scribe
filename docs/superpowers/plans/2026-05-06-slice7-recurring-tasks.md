# Slice 7 — Recurring Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add recurring task support — a pure-Swift RRULE parser/engine, store-level completion advancement, and a 1.5 s "just completed" UX shimmer in the task list.

**Architecture:** `RecurrenceRule` parses/serialises RRULE strings into a typed value. `RecurrenceEngine` computes next occurrences as pure static functions. `TaskStore.completeTask` advances `dueAt` in-place for recurring tasks instead of setting `completedAt`. `TaskListViewModel` temporarily tracks recently-completed recurring IDs so the UI shows strikethrough during the 1.5 s window.

**Tech Stack:** Swift 6, GRDB (already in use), `Calendar` with UTC timezone for all date arithmetic, XCTest.

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `Scribe/Tasks/RecurrenceRule.swift` | **Create** | `RecurrenceError`, `RecurrenceRule` struct, parse + serialise |
| `Scribe/Tasks/RecurrenceEngine.swift` | **Create** | `Calendar.utcCalendar`, `RecurrenceEngine` static methods |
| `Scribe/Storage/TaskStore.swift` | **Modify** | `TaskStoreError`, validation, recurrence branch in `completeTask` |
| `Scribe/UI/Tasks/TaskListViewModel.swift` | **Modify** | `recentlyCompletedRecurring` state + 1.5 s clear |
| `Scribe/UI/Tasks/TaskListView.swift` | **Modify** | Pass `isRecentlyCompleted` to `TaskRowView` |
| `ScribeTests/RecurrenceRuleTests.swift` | **Create** | Parse round-trips, error paths |
| `ScribeTests/RecurrenceEngineTests.swift` | **Create** | DAILY, WEEKLY, MONTHLY, DST boundary cases |
| `ScribeTests/TaskStoreTests.swift` | **Modify** | 4 new test cases for recurrence + validation |

---

## Task 1: `RecurrenceRule` — struct, parser, serialiser

**Files:**
- Create: `Scribe/Tasks/RecurrenceRule.swift`
- Create: `ScribeTests/RecurrenceRuleTests.swift`

- [ ] **Step 1: Create the test file with failing tests**

Create `ScribeTests/RecurrenceRuleTests.swift`:

```swift
import XCTest
@testable import Scribe

final class RecurrenceRuleTests: XCTestCase {

    // MARK: - Parsing

    func testParseDailyDefault() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        XCTAssertEqual(rule.frequency, .daily)
        XCTAssertEqual(rule.interval, 1)
        XCTAssertTrue(rule.byDay.isEmpty)
        XCTAssertNil(rule.byMonthDay)
    }

    func testParseDailyWithInterval() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3")
        XCTAssertEqual(rule.frequency, .daily)
        XCTAssertEqual(rule.interval, 3)
    }

    func testParseWeeklyMultiDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.byDay, [.mo, .we, .fr])
        XCTAssertNil(rule.byMonthDay)
    }

    func testParseMonthlyOrdinalPositive() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=2MO")
        XCTAssertEqual(rule.frequency, .monthly)
        XCTAssertEqual(rule.byMonthDay?.ordinal, 2)
        XCTAssertEqual(rule.byMonthDay?.weekday, .mo)
        XCTAssertTrue(rule.byDay.isEmpty)
    }

    func testParseMonthlyOrdinalNegative() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        XCTAssertEqual(rule.byMonthDay?.ordinal, -1)
        XCTAssertEqual(rule.byMonthDay?.weekday, .fr)
    }

    func testParseUnknownKeysIgnored() throws {
        // Forward-compat: unknown keys must not throw.
        let rule = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231T000000Z")
        XCTAssertEqual(rule.frequency, .daily)
    }

    func testParseMissingFreqThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("INTERVAL=1")) { error in
            guard case RecurrenceError.invalidRule = error else {
                XCTFail("Expected RecurrenceError.invalidRule, got \(error)")
                return
            }
        }
    }

    func testParseInvalidFreqThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=YEARLY")) { error in
            guard case RecurrenceError.invalidRule = error else {
                XCTFail("Expected RecurrenceError.invalidRule")
                return
            }
        }
    }

    func testParseInvalidIntervalThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=0"))
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=-1"))
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=abc"))
    }

    func testParseInvalidBydayThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=XX"))
    }

    // MARK: - Serialisation round-trips

    func testRoundTripDaily() throws {
        let original = "FREQ=DAILY"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripDailyInterval() throws {
        let original = "FREQ=DAILY;INTERVAL=3"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripWeeklyMultiDay() throws {
        let original = "FREQ=WEEKLY;BYDAY=MO,WE,FR"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripMonthlyOrdinal() throws {
        let original = "FREQ=MONTHLY;BYDAY=2MO"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripMonthlyLastFriday() throws {
        let original = "FREQ=MONTHLY;BYDAY=-1FR"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```bash
swift test --filter RecurrenceRuleTests 2>&1 | tail -5
```

Expected: compile error — `RecurrenceRule` not defined.

- [ ] **Step 3: Create `Scribe/Tasks/RecurrenceRule.swift`**

```swift
import Foundation

enum RecurrenceError: LocalizedError {
    case invalidRule(String)

    var errorDescription: String? {
        if case .invalidRule(let r) = self { return "Invalid recurrence rule: \(r)" }
        return nil
    }
}

struct RecurrenceRule: Equatable {

    enum Frequency: String {
        case daily   = "DAILY"
        case weekly  = "WEEKLY"
        case monthly = "MONTHLY"
    }

    enum Weekday: String, CaseIterable, Equatable {
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

    struct OrdinalWeekday: Equatable {
        let ordinal: Int    // 1…5 = Nth; -1 = last
        let weekday: Weekday
    }

    let frequency: Frequency
    let interval: Int                   // ≥ 1; default 1
    let byDay: [Weekday]                // WEEKLY multi-day list
    let byMonthDay: OrdinalWeekday?     // MONTHLY ordinal weekday

    // MARK: - Serialisation

    var rruleString: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if let ord = byMonthDay {
            parts.append("BYDAY=\(ord.ordinal)\(ord.weekday.rawValue)")
        } else if !byDay.isEmpty {
            parts.append("BYDAY=\(byDay.map(\.rawValue).joined(separator: ","))")
        }
        return parts.joined(separator: ";")
    }

    // MARK: - Parsing

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
        var byMonthDay: OrdinalWeekday? = nil

        if let bydayStr = pairs["BYDAY"] {
            // Ordinal prefix pattern: -1FR, 2MO, etc.
            let pattern = try! NSRegularExpression(pattern: #"^(-?[1-5])([A-Z]{2})$"#)
            let nsStr = bydayStr as NSString
            let range = NSRange(location: 0, length: nsStr.length)
            if let match = pattern.firstMatch(in: bydayStr, range: range) {
                let ordStr = nsStr.substring(with: match.range(at: 1))
                let wdStr  = nsStr.substring(with: match.range(at: 2))
                guard let ordinal = Int(ordStr), let weekday = Weekday(rawValue: wdStr) else {
                    throw RecurrenceError.invalidRule(rrule)
                }
                byMonthDay = OrdinalWeekday(ordinal: ordinal, weekday: weekday)
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
            byMonthDay: byMonthDay
        )
    }
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```bash
swift test --filter RecurrenceRuleTests 2>&1 | tail -5
```

Expected: all `RecurrenceRuleTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/Tasks/RecurrenceRule.swift ScribeTests/RecurrenceRuleTests.swift
git commit -m "feat(tasks): add RecurrenceRule RRULE parser and serialiser"
```

---

## Task 2: `RecurrenceEngine` — DAILY and `Calendar.utcCalendar`

**Files:**
- Create: `Scribe/Tasks/RecurrenceEngine.swift`
- Create: `ScribeTests/RecurrenceEngineTests.swift`

- [ ] **Step 1: Create the test file with DAILY tests**

Create `ScribeTests/RecurrenceEngineTests.swift`:

```swift
import XCTest
@testable import Scribe

final class RecurrenceEngineTests: XCTestCase {

    // Convenience: build a UTC Date from components.
    private func utc(_ year: Int, _ month: Int, _ day: Int,
                     hour: Int = 0, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar.utcCalendar.date(from: c)!
    }

    // MARK: - DAILY

    func testDailyAdvancesByOneDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 1), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 2))
    }

    func testDailyWithIntervalThree() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 1), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 4))
    }

    func testDailyAcrossMonthBoundary() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 31), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 1))
    }

    func testDailyAcrossYearBoundary() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let next = RecurrenceEngine.nextDate(after: utc(2025, 12, 31), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 1))
    }
}
```

- [ ] **Step 2: Run tests — confirm compile error**

```bash
swift test --filter RecurrenceEngineTests 2>&1 | tail -5
```

Expected: compile error — `RecurrenceEngine` / `Calendar.utcCalendar` not defined.

- [ ] **Step 3: Create `Scribe/Tasks/RecurrenceEngine.swift` with DAILY only**

```swift
import Foundation

extension Calendar {
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}

enum RecurrenceEngine {

    static func nextDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar = .utcCalendar
    ) -> Date {
        switch rule.frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date)!
        case .weekly:
            return nextWeeklyDate(after: date, rule: rule, calendar: calendar)
        case .monthly:
            return nextMonthlyDate(after: date, rule: rule, calendar: calendar)
        }
    }

    // MARK: - WEEKLY (stub — Task 3)

    private static func nextWeeklyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        // Implemented in Task 3.
        return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)!
    }

    // MARK: - MONTHLY (stub — Task 4)

    private static func nextMonthlyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        // Implemented in Task 4.
        return calendar.date(byAdding: .month, value: rule.interval, to: date)!
    }
}
```

- [ ] **Step 4: Run tests — confirm DAILY tests pass**

```bash
swift test --filter RecurrenceEngineTests 2>&1 | tail -5
```

Expected: 4 DAILY tests pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/Tasks/RecurrenceEngine.swift ScribeTests/RecurrenceEngineTests.swift
git commit -m "feat(tasks): add RecurrenceEngine with DAILY support"
```

---

## Task 3: `RecurrenceEngine` — WEEKLY

**Files:**
- Modify: `Scribe/Tasks/RecurrenceEngine.swift`
- Modify: `ScribeTests/RecurrenceEngineTests.swift`

- [ ] **Step 1: Add WEEKLY tests to `RecurrenceEngineTests.swift`**

Add these test methods to the existing `RecurrenceEngineTests` class (after `testDailyAcrossYearBoundary`):

```swift
    // MARK: - WEEKLY

    func testWeeklySingleDayAdvancesByOneWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        // Monday 2026-01-05 → Monday 2026-01-12
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 12))
    }

    func testWeeklyIntervalTwoAdvancesByTwoWeeks() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2")
        // Monday 2026-01-05 → Monday 2026-01-19
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 19))
    }

    func testWeeklyMultiDayAdvancesWithinWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // Monday 2026-01-05 → Wednesday 2026-01-07
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 7))
    }

    func testWeeklyMultiDayAdvancesWithinWeekMidWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // Wednesday 2026-01-07 → Friday 2026-01-09
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 7), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 9))
    }

    func testWeeklyMultiDayWrapsToNextWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // Friday 2026-01-09 → Monday 2026-01-12
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 9), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 12))
    }

    func testWeeklyMultiDayIntervalTwoWraps() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR")
        // Friday 2026-01-09 → Monday 2026-01-19 (skip week of Jan 12)
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 9), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 19))
    }

    // DST: UTC clocks don't shift — the date arithmetic stays exact.
    func testWeeklyAcrossDSTSpringForward() throws {
        // US clocks spring forward 2026-03-08. Stored in UTC → no shift.
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        let before = utc(2026, 3, 7, hour: 2)
        let next = RecurrenceEngine.nextDate(after: before, rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 14, hour: 2))
    }

    func testWeeklyAcrossDSTFallBack() throws {
        // US clocks fall back 2026-11-01. Stored in UTC → no shift.
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        let before = utc(2026, 10, 31, hour: 1)
        let next = RecurrenceEngine.nextDate(after: before, rule: rule)
        XCTAssertEqual(next, utc(2026, 11, 7, hour: 1))
    }
```

- [ ] **Step 2: Run new WEEKLY tests — confirm they fail**

```bash
swift test --filter RecurrenceEngineTests 2>&1 | grep -E "FAIL|passed|failed" | tail -10
```

Expected: WEEKLY multi-day and interval-2 tests fail (stub returns wrong value).

- [ ] **Step 3: Replace the `nextWeeklyDate` stub with full implementation**

Replace the `nextWeeklyDate` method body in `Scribe/Tasks/RecurrenceEngine.swift`:

```swift
    private static func nextWeeklyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        guard !rule.byDay.isEmpty else {
            // Single-day weekly: advance by interval weeks.
            return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)!
        }

        let sorted = rule.byDay.sorted { $0.calendarWeekday < $1.calendarWeekday }
        let currentWeekday = calendar.component(.weekday, from: date)

        // If any BYDAY weekday comes later this week, advance to it.
        if let next = sorted.first(where: { $0.calendarWeekday > currentWeekday }) {
            return calendar.date(byAdding: .day,
                                 value: next.calendarWeekday - currentWeekday,
                                 to: date)!
        }

        // Otherwise wrap: days to first BYDAY in the next `interval` week(s).
        let firstWeekday = sorted.first!.calendarWeekday
        let daysToFirst = (firstWeekday - currentWeekday + 7) % 7
        // daysToFirst == 0 only if today IS firstWeekday; wrapping means +7.
        let normalised = daysToFirst == 0 ? 7 : daysToFirst
        let total = normalised + (rule.interval - 1) * 7
        return calendar.date(byAdding: .day, value: total, to: date)!
    }
```

- [ ] **Step 4: Run all WEEKLY tests — confirm they pass**

```bash
swift test --filter RecurrenceEngineTests 2>&1 | tail -5
```

Expected: all `RecurrenceEngineTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/Tasks/RecurrenceEngine.swift ScribeTests/RecurrenceEngineTests.swift
git commit -m "feat(tasks): implement WEEKLY recurrence with multi-day and interval support"
```

---

## Task 4: `RecurrenceEngine` — MONTHLY

**Files:**
- Modify: `Scribe/Tasks/RecurrenceEngine.swift`
- Modify: `ScribeTests/RecurrenceEngineTests.swift`

- [ ] **Step 1: Add MONTHLY tests to `RecurrenceEngineTests.swift`**

Add these test methods after the WEEKLY tests:

```swift
    // MARK: - MONTHLY

    func testMonthlyDayOfMonthAdvancesByOneMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY")
        // 2026-01-15 → 2026-02-15
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 15), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 15))
    }

    func testMonthlyDayOfMonthIntervalTwo() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2")
        // 2026-01-15 → 2026-03-15
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 15), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 15))
    }

    func testMonthlyOrdinalSecondMonday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=2MO")
        // Jan 2026: 2nd Monday = Jan 12. From Jan 12 → Feb 2026 2nd Monday = Feb 9.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 12), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 9))
    }

    func testMonthlyOrdinalFirstWednesday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=1WE")
        // Feb 2026: 1st Wednesday = Feb 4. From Feb 4 → Mar 4 (1st Wed of March).
        let next = RecurrenceEngine.nextDate(after: utc(2026, 2, 4), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 4))
    }

    func testMonthlyOrdinalLastFriday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        // Jan 2026 last Friday = Jan 30. → Feb 2026 last Friday = Feb 27.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 30), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 27))
    }

    func testMonthlyOrdinalLastFridayFebruaryToMarch() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        // Feb 2026 last Friday = Feb 27 → Mar 2026 last Friday = Mar 27.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 2, 27), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 27))
    }

    func testMonthlyIntervalTwoOrdinal() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2;BYDAY=1MO")
        // Jan 2026 1st Monday = Jan 5 → skip Feb → Mar 2 (1st Mon of March).
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 2))
    }
```

- [ ] **Step 2: Run new MONTHLY tests — confirm they fail**

```bash
swift test --filter RecurrenceEngineTests 2>&1 | grep -E "FAIL|failed" | tail -10
```

Expected: ordinal tests fail (stub returns raw month advance without weekday adjustment).

- [ ] **Step 3: Replace the `nextMonthlyDate` stub with full implementation**

Replace the `nextMonthlyDate` method body and add the `nthWeekdayInMonth` helper in `Scribe/Tasks/RecurrenceEngine.swift`:

```swift
    private static func nextMonthlyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        let anchor = calendar.date(byAdding: .month, value: rule.interval, to: date)!
        guard let ordinal = rule.byMonthDay else { return anchor }
        return nthWeekdayInMonth(ordinal: ordinal.ordinal,
                                 weekday: ordinal.weekday,
                                 in: anchor,
                                 calendar: calendar)
    }

    /// Returns the Nth occurrence of `weekday` in the month containing `date`.
    /// `ordinal` 1…5 = first…fifth; -1 = last.
    private static func nthWeekdayInMonth(
        ordinal: Int,
        weekday: RecurrenceRule.Weekday,
        in date: Date,
        calendar: Calendar
    ) -> Date {
        let targetWeekday = weekday.calendarWeekday
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!

        if ordinal > 0 {
            let firstWeekday = calendar.component(.weekday, from: monthStart)
            let offset = (targetWeekday - firstWeekday + 7) % 7
            let dayOffset = offset + (ordinal - 1) * 7
            return calendar.date(byAdding: .day, value: dayOffset, to: monthStart)!
        } else {
            // Negative: count back from last day of month.
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonthStart)!
            let lastWeekday = calendar.component(.weekday, from: lastDay)
            let offset = (lastWeekday - targetWeekday + 7) % 7
            let dayOffset = offset + (abs(ordinal) - 1) * 7
            return calendar.date(byAdding: .day, value: -dayOffset, to: lastDay)!
        }
    }
```

- [ ] **Step 4: Run all engine tests — confirm they pass**

```bash
swift test --filter RecurrenceEngineTests 2>&1 | tail -5
```

Expected: all `RecurrenceEngineTests` pass (DAILY + WEEKLY + MONTHLY + DST).

- [ ] **Step 5: Run full test suite — confirm no regressions**

```bash
swift test 2>&1 | tail -5
```

Expected: 108+ tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Scribe/Tasks/RecurrenceEngine.swift ScribeTests/RecurrenceEngineTests.swift
git commit -m "feat(tasks): implement MONTHLY recurrence with ordinal weekday support"
```

---

## Task 5: `TaskStore` — validation and `completeTask` recurrence branch

**Files:**
- Modify: `Scribe/Storage/TaskStore.swift`
- Modify: `ScribeTests/TaskStoreTests.swift`

- [ ] **Step 1: Add 4 failing tests to `ScribeTests/TaskStoreTests.swift`**

Find the end of `TaskStoreTests` class and add:

```swift
    // MARK: - Recurrence

    func testCreateRecurringTaskWithoutDueDateThrows() throws {
        XCTAssertThrowsError(
            try store.createTask(title: "Daily standup", recurrenceRule: "FREQ=DAILY")
        ) { error in
            guard case TaskStoreError.recurringTaskRequiresDueDate = error else {
                XCTFail("Expected TaskStoreError.recurringTaskRequiresDueDate, got \(error)")
                return
            }
        }
    }

    func testUpdateTaskAddingRecurrenceWithoutDueDateThrows() throws {
        var task = try store.createTask(title: "No due date task")
        task.recurrenceRule = "FREQ=WEEKLY"
        XCTAssertThrowsError(try store.updateTask(task)) { error in
            guard case TaskStoreError.recurringTaskRequiresDueDate = error else {
                XCTFail("Expected TaskStoreError.recurringTaskRequiresDueDate, got \(error)")
                return
            }
        }
    }

    func testCompleteRecurringTaskAdvancesDueDateAndClearsCompletedAt() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000) // fixed UTC timestamp
        let task = try store.createTask(
            title: "Daily standup",
            dueAt: due,
            recurrenceRule: "FREQ=DAILY"
        )
        try store.completeTask(id: task.id, at: due)

        let updated = try XCTUnwrap(store.fetchTask(id: task.id))
        // completedAt must be nil — task stays active
        XCTAssertNil(updated.completedAt)
        // dueAt must have advanced by 1 day
        let expectedDue = Calendar.utcCalendar.date(byAdding: .day, value: 1, to: due)!
        XCTAssertEqual(updated.dueAt, expectedDue)
    }

    func testCompleteRecurringTaskInsertsHistoryRow() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = try store.createTask(
            title: "Weekly review",
            dueAt: due,
            recurrenceRule: "FREQ=WEEKLY"
        )
        try store.completeTask(id: task.id, at: due)

        let count = try manager.database.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM task_completions WHERE taskId = ?",
                arguments: [task.id])
        }
        XCTAssertEqual(count, 1)
    }
```

- [ ] **Step 2: Run new tests — confirm they fail**

```bash
swift test --filter TaskStoreTests 2>&1 | grep -E "FAIL|failed" | tail -5
```

Expected: 4 new tests fail — `TaskStoreError` not defined, validation not present.

- [ ] **Step 3: Add `TaskStoreError` and validation to `TaskStore.swift`**

At the top of `TaskStore.swift`, before the `final class TaskStore` declaration, add:

```swift
enum TaskStoreError: LocalizedError {
    case recurringTaskRequiresDueDate

    var errorDescription: String? {
        switch self {
        case .recurringTaskRequiresDueDate:
            return "A recurring task must have a due date."
        }
    }
}
```

After the `normalisedTags` helper at the bottom of `TaskStore`, add a private validation helper:

```swift
    private func validateRecurrence(rule: String?, dueAt: Date?) throws {
        if rule != nil && dueAt == nil {
            throw TaskStoreError.recurringTaskRequiresDueDate
        }
    }
```

In `createTask`, add validation immediately before `try task.insert(database)`:

```swift
            try validateRecurrence(rule: recurrenceRule, dueAt: dueAt)
```

In `updateTask`, add validation before `try copy.update($0)`:

```swift
    func updateTask(_ task: TodoTask) throws {
        var copy = task
        copy.updatedAt = Date()
        try db.write {
            try validateRecurrence(rule: copy.recurrenceRule, dueAt: copy.dueAt)
            try copy.update($0)
        }
    }
```

- [ ] **Step 4: Update `completeTask` with the recurrence branch**

Replace the existing `completeTask` method with:

```swift
    func completeTask(id: String, at date: Date = Date()) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            try TaskCompletion(taskId: id, completedAt: date).insert(database)

            if let ruleStr = task.recurrenceRule,
               let due = task.dueAt,
               let rule = try? RecurrenceRule.parse(ruleStr) {
                task.dueAt = RecurrenceEngine.nextDate(after: due, rule: rule)
                task.completedAt = nil
            } else {
                task.completedAt = date
            }

            task.updatedAt = date
            try task.update(database)
        }
    }
```

- [ ] **Step 5: Run full test suite — confirm all pass**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass (4 new + 108 existing).

- [ ] **Step 6: Commit**

```bash
git add Scribe/Storage/TaskStore.swift ScribeTests/TaskStoreTests.swift
git commit -m "feat(tasks): add recurrence validation and completeTask advancement in TaskStore"
```

---

## Task 6: `TaskListViewModel` — `recentlyCompletedRecurring` state

**Files:**
- Modify: `Scribe/UI/Tasks/TaskListViewModel.swift`

- [ ] **Step 1: Add `recentlyCompletedRecurring` published property**

In `TaskListViewModel.swift`, in the `// MARK: - Published state` section, add after `@Published var quickAddText`:

```swift
    /// IDs of recurring tasks completed in the last 1.5 s. Used to keep
    /// strikethrough visible while the DB row is already advanced to the
    /// next occurrence.
    @Published private(set) var recentlyCompletedRecurring: Set<String> = []
```

- [ ] **Step 2: Update `toggleCompleted` to populate the set**

Replace the existing `toggleCompleted` method with:

```swift
    func toggleCompleted(_ task: TodoTask) {
        do {
            if task.isCompleted {
                try store.uncompleteTask(id: task.id)
            } else {
                try store.completeTask(id: task.id)
                if task.recurrenceRule != nil {
                    recentlyCompletedRecurring.insert(task.id)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        self?.recentlyCompletedRecurring.remove(task.id)
                    }
                }
            }
        } catch {
            Log.ui.error("TaskListViewModel.toggleCompleted failed: \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 3: Build — confirm no compile errors**

```bash
swift build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/Tasks/TaskListViewModel.swift
git commit -m "feat(tasks): add recentlyCompletedRecurring state with 1.5s auto-clear"
```

---

## Task 7: `TaskListView` — pass `isRecentlyCompleted` to `TaskRowView`

**Files:**
- Modify: `Scribe/UI/Tasks/TaskListView.swift`

- [ ] **Step 1: Update `section(for:tasks:)` to pass `isRecentlyCompleted`**

In `TaskListView.swift`, find the `ForEach(tasks)` block inside `section(for:tasks:)` and replace it:

```swift
            ForEach(tasks) { task in
                TaskRowView(
                    task: task,
                    isRecentlyCompleted: viewModel.recentlyCompletedRecurring.contains(task.id),
                    onToggle: { viewModel.toggleCompleted(task) }
                )
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.delete(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
```

- [ ] **Step 2: Add `isRecentlyCompleted` parameter to `TaskRowView`**

In the `// MARK: - Row` section, update `TaskRowView`:

```swift
struct TaskRowView: View {
    let task: TodoTask
    let isRecentlyCompleted: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .font(.system(.body, weight: .regular))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(.body))
                    .strikethrough(task.isCompleted || isRecentlyCompleted, color: .secondary)
                    .foregroundStyle(task.isCompleted || isRecentlyCompleted ? .secondary : .primary)
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let due = task.dueAt {
                DueDateChip(date: due, isOverdue: !task.isCompleted && due < Calendar.current.startOfDay(for: Date()))
            }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
    }
}
```

- [ ] **Step 3: Build — confirm no compile errors**

```bash
swift build 2>&1 | grep -E "error:" | head -10
```

Expected: no errors.

- [ ] **Step 4: Run full test suite**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/Tasks/TaskListView.swift
git commit -m "feat(tasks): render strikethrough for recently completed recurring tasks"
```

---

## Task 8: Regenerate Xcode project

**Files:**
- Modify: `Scribe.xcodeproj/` (generated)

- [ ] **Step 1: Run xcodegen**

```bash
xcodegen 2>&1 | tail -5
```

Expected: `✔ Done` — project file regenerated with `Scribe/Tasks/*.swift` included.

- [ ] **Step 2: Verify Xcode build**

```bash
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Scribe.xcodeproj
git commit -m "chore: regenerate Xcode project for Scribe/Tasks/ source group"
```

---

## Task 9: Final verification

- [ ] **Step 1: Run full test suite one last time**

```bash
swift test 2>&1 | tail -8
```

Expected: all tests pass, 0 failures, test count ≥ 130 (108 baseline + ~22 new).

- [ ] **Step 2: Confirm new test files exist**

```bash
ls ScribeTests/Recurrence*.swift ScribeTests/TaskStoreTests.swift
```

Expected:
```
ScribeTests/RecurrenceEngineTests.swift
ScribeTests/RecurrenceRuleTests.swift
ScribeTests/TaskStoreTests.swift
```

- [ ] **Step 3: Confirm new source files exist**

```bash
ls Scribe/Tasks/
```

Expected:
```
RecurrenceEngine.swift
RecurrenceRule.swift
```
