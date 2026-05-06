# Slice 7 — Recurring Tasks Design

**Date:** 2026-05-06  
**Branch:** feat/tasks-slice-7-recurring  
**Scope:** Engine + store changes only. Picker UI deferred to slice 3 (editor pane).

---

## Decisions

| Question | Decision |
|---|---|
| Recurring task with no `dueAt` | Validation error — disallowed at `createTask`/`updateTask` |
| On completion | Advance `dueAt` in-place, clear `completedAt`, insert `TaskCompletion` history row |
| "Just completed" UX | `TaskListViewModel` holds `recentlyCompletedRecurring: Set<String>` — cleared after 1.5 s |
| MONTHLY + BYDAY | Ordinal weekday only: `BYDAY=2MO` = 2nd Monday of each month |
| Picker UI | Not in this slice — deferred to slice 3 |
| DST handling | UTC storage + `Calendar.date(byAdding:)` with UTC calendar — no special handling needed |
| Parser approach | Regex-based Swift parser (no EventKit, no JSON schema) |

---

## Architecture

### `RecurrenceRule` (new file: `Scribe/Tasks/RecurrenceRule.swift`)

Pure value type. No DB or UI dependencies.

```swift
struct RecurrenceRule: Equatable {
    enum Frequency { case daily, weekly, monthly }
    enum Weekday: String { case mo, tu, we, th, fr, sa, su }

    struct OrdinalWeekday: Equatable {   // for MONTHLY
        let ordinal: Int   // 1…5, -1 = last
        let weekday: Weekday
    }

    let frequency: Frequency
    let interval: Int                       // default 1
    let byDay: [Weekday]                    // WEEKLY multi-day
    let byMonthDay: OrdinalWeekday?         // MONTHLY ordinal weekday
}
```

**Parsing:** `RecurrenceRule.parse(_ rrule: String) throws -> RecurrenceRule`  
Splits on `;`, matches `KEY=VALUE` pairs. Unknown keys are ignored (forward-compat). Throws `RecurrenceError.invalidRule(String)` for malformed input.

**Serialisation:** `var rruleString: String` — round-trips to canonical RRULE string.

---

### `RecurrenceEngine` (new file: `Scribe/Tasks/RecurrenceEngine.swift`)

Static methods only. No state, no DB, no UI.

```swift
enum RecurrenceEngine {
    static func nextDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar = .utcCalendar
    ) -> Date
}
```

**DAILY:** `calendar.date(byAdding: .day, value: rule.interval, to: date)`

**WEEKLY:** Advance by `interval` weeks from `date`, then find the nearest `byDay` weekday on or after that anchor. If `byDay` is empty, treat as single-day weekly (advance by `interval` weeks).

**MONTHLY ordinal weekday:** Advance by `interval` months, then find the Nth weekday of the resulting month. If `byMonthDay` is nil, advance to same day-of-month.

**DST:** All computation uses `Calendar` with `TimeZone(identifier: "UTC")` (exposed as `Calendar.utcCalendar` extension). Dates stored as UTC epoch seconds in SQLite via GRDB's default `Date` encoding.

---

### `TaskStore` changes (`Scribe/Storage/TaskStore.swift`)

**Validation** — extracted helper:
```swift
private func validateRecurrence(_ task: TodoTask) throws {
    if task.recurrenceRule != nil && task.dueAt == nil {
        throw TaskStoreError.recurringTaskRequiresDueDate
    }
}
```
Called from `createTask` and `updateTask`.

**`completeTask(id:at:)` update:**
```
1. Fetch task
2. Insert TaskCompletion history row  ← already exists
3. If task.recurrenceRule != nil:
     a. Parse rule via RecurrenceRule.parse
     b. Compute nextDue = RecurrenceEngine.nextDate(after: task.dueAt!, rule:)
     c. task.dueAt = nextDue
     d. task.completedAt = nil   ← advance in-place, stay active
     e. task.updatedAt = now
4. Else: task.completedAt = date (existing behaviour)
5. task.update(database)
```
Single DB write — fetch + history insert + task update are all inside `db.write { }`.

---

### `TaskListViewModel` changes (`Scribe/UI/Tasks/TaskListViewModel.swift`)

Add:
```swift
@Published private(set) var recentlyCompletedRecurring: Set<String> = []
```

In `toggleCompleted(_:)`, after calling `store.completeTask`:
- If the task had a `recurrenceRule`, insert its `id` into `recentlyCompletedRecurring`
- Fire a detached `Task { try? await Task.sleep(for: .seconds(1.5)); ... remove id }` on `@MainActor`

`TaskRowView` receives `isRecentlyCompleted: Bool`. Renders strikethrough when `task.isCompleted || isRecentlyCompleted`.

---

### No DB migration needed

`recurrenceRule` column and `task_completions` table already exist (v3). No schema changes.

---

## Error Types

```swift
enum RecurrenceError: Error {
    case invalidRule(String)
}

enum TaskStoreError: Error {
    case recurringTaskRequiresDueDate
}
```

---

## Tests

### `RecurrenceEngineTests` (new)

| Case | Input | Expected |
|---|---|---|
| DAILY | 2026-01-01, FREQ=DAILY | 2026-01-02 |
| DAILY INTERVAL=3 | 2026-01-01, FREQ=DAILY;INTERVAL=3 | 2026-01-04 |
| WEEKLY single day | Mon 2026-01-05, FREQ=WEEKLY | Mon 2026-01-12 |
| WEEKLY multi-day MO,WE,FR | Mon 2026-01-05 | Wed 2026-01-07 |
| WEEKLY multi-day MO,WE,FR | Fri 2026-01-09 | Mon 2026-01-12 |
| WEEKLY INTERVAL=2 | Mon 2026-01-05, FREQ=WEEKLY;INTERVAL=2 | Mon 2026-01-19 |
| MONTHLY day-of-month | 2026-01-15, FREQ=MONTHLY | 2026-02-15 |
| MONTHLY ordinal 2MO | Jan 2026, FREQ=MONTHLY;BYDAY=2MO | 2nd Mon Feb 2026 |
| MONTHLY ordinal -1FR | Jan 2026, FREQ=MONTHLY;BYDAY=-1FR | last Fri Feb 2026 |
| DST spring forward | 2026-03-07 02:00 UTC, FREQ=WEEKLY | 2026-03-14 02:00 UTC |
| DST fall back | 2026-10-31 01:00 UTC, FREQ=WEEKLY | 2026-11-07 01:00 UTC |

### `RecurrenceRuleTests` (new)

Round-trip parse/serialise for all supported FREQ values. Error thrown on malformed input.

### `TaskStoreTests` additions

- `completeRecurringTask_advancesDueAt` — verify `dueAt` advances, `completedAt` nil, history row inserted
- `completeNonRecurringTask_setsCompletedAt` — existing behaviour unchanged
- `createRecurringTaskWithoutDueDate_throws` — validation error path
- `updateTaskAddingRecurrenceWithoutDueDate_throws` — validation error on update path

---

## Files Changed

| File | Change |
|---|---|
| `Scribe/Tasks/RecurrenceRule.swift` | New |
| `Scribe/Tasks/RecurrenceEngine.swift` | New |
| `Scribe/Storage/TaskStore.swift` | Validation + completeTask recurrence branch |
| `Scribe/UI/Tasks/TaskListViewModel.swift` | `recentlyCompletedRecurring` state |
| `Scribe/UI/Tasks/TaskListView.swift` | Pass `isRecentlyCompleted` to `TaskRowView` |
| `ScribeTests/RecurrenceRuleTests.swift` | New |
| `ScribeTests/RecurrenceEngineTests.swift` | New |
| `ScribeTests/TaskStoreTests.swift` | Add 4 test cases |

No new directory needed — `Scribe/Tasks/` is a logical grouping; `xcodegen` will pick it up.

---

## Out of Scope

- Picker UI (slice 3)
- `UNTIL` / `COUNT` RRULE clauses
- `BYSETPOS`
- `FREQ=YEARLY`
- Reminder rescheduling on advance (slice 6)
