# Meeting Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Link Notes ↔ recording Sessions so a Note can own many sessions and surface each session's AI summary, action items, and entities/topics alongside the user's freeform writing.

**Architecture:** Add a nullable `sessions.noteId` column. Notes render a "Sessions strip" with one chip per linked session and an expanded per-session auto-section sourced live from existing `meeting_summaries` / `action_items` / `extracted_entities`. Recording from inside a Note (or globally with a Note selected) binds the new session to that Note; recording with nothing selected auto-creates a "Meeting on …" Note.

**Tech Stack:** Swift 6, SwiftUI, AppKit, GRDB.swift (SQLite + FTS5), Apple Speech, FoundationModels, NaturalLanguage, ScreenCaptureKit, AVFoundation, XCTest, SwiftPM (`swift test`).

**Slicing:** This plan covers Slices 15–19 from the spec. Each slice ends with a green test run and a commit. Slice 15 is shippable on its own. Slice 16 unlocks user-visible value but expects a session that's already bound via slice 15's APIs. Slice 17 makes binding accessible to the user without SQL.

---

## Project conventions (read once before starting)

- All Swift sources live under `Scribe/`, mirrored test files under `ScribeTests/`.
- Run tests with `swift test`. Filter to a class with `swift test --filter ClassName`.
- After adding or removing source files, regenerate the Xcode project: `xcodegen`.
- DB migrations are additive only. Tests use `DatabaseManager(path: ":memory:")` — never reach into the on-disk DB from a test.
- Stores expose CRUD plus `observe…` Combine publishers (`ValueObservation.tracking(...).publisher(in: db, scheduling: .async(onQueue: .main))`).
- ViewModels are `@MainActor` `ObservableObject`s in `Scribe/UI/<Feature>/`.
- Logging via `Log.<subsystem>` from `Scribe/Utilities/Log.swift`.
- Notification names live as `extension Notification.Name` in `Scribe/UI/MainWindow/MainWindowView.swift`.

---

## Slice 15 — Storage & migration

Adds the `sessions.noteId` column, extends `Session`, and surfaces bind/observe APIs on `TranscriptStore`. Sweep `NoteStore.deleteNote(id:)` so transcripts outlive note deletion. No UI change.

### Task 15.1: Migration `v10_session_noteId`

**Files:**
- Modify: `Scribe/Storage/DatabaseManager.swift` (registerMigration block, after `v9_restore_note_links_fk`)
- Test: `ScribeTests/SessionNoteIdMigrationTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `ScribeTests/SessionNoteIdMigrationTests.swift`:

```swift
// ScribeTests/SessionNoteIdMigrationTests.swift
import XCTest
import GRDB
@testable import Scribe

final class SessionNoteIdMigrationTests: XCTestCase {
    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        db = try! DatabaseManager(path: ":memory:")
    }

    override func tearDown() { db = nil }

    func testSessionsHasNoteIdColumn() throws {
        let columns: [String] = try db.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(sessions)")
                .compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("noteId"),
                      "sessions table must have a noteId column after v10 migration")
    }

    func testSessionsNoteIdIndexExists() throws {
        let names: [String] = try db.database.read { database in
            try String.fetchAll(database,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='sessions'")
        }
        XCTAssertTrue(names.contains("sessions_noteId_idx"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionNoteIdMigrationTests`
Expected: FAIL — `sessions` has no `noteId` column.

- [ ] **Step 3: Add the migration**

In `Scribe/Storage/DatabaseManager.swift`, register a new migration immediately **after** the existing `v9_restore_note_links_fk` migration (i.e. as the last `registerMigration` call before `try migrator.migrate(database)`):

```swift
migrator.registerMigration("v10_session_noteId") { db in
    // sessions.noteId — links a recording session to a Note.
    // Nullable (NULL = unattached). FK is NOT enforced via ALTER TABLE in
    // this codebase (matches notes.notebookId pattern); NoteStore.deleteNote
    // is responsible for sweeping noteId to NULL before deleting a note so
    // transcripts survive note deletion.
    try db.alter(table: "sessions") { t in
        t.add(column: "noteId", .text)
    }
    try db.create(index: "sessions_noteId_idx",
                  on: "sessions",
                  columns: ["noteId"])
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionNoteIdMigrationTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Scribe/Storage/DatabaseManager.swift ScribeTests/SessionNoteIdMigrationTests.swift
git commit -m "feat(storage): migration v10 adds sessions.noteId column + index"
```

---

### Task 15.2: Extend `Session` with `noteId`

**Files:**
- Modify: `Scribe/Storage/Session.swift`
- Test: `ScribeTests/SessionNoteIdMigrationTests.swift` (add round-trip case)

- [ ] **Step 1: Write the failing test**

Append to `ScribeTests/SessionNoteIdMigrationTests.swift`:

```swift
    func testSessionRoundTripsNoteId() throws {
        let session = Session(title: "T", noteId: "note-42")
        try db.database.write { try session.insert($0) }
        let fetched = try db.database.read { try Session.fetchOne($0, key: session.id) }
        XCTAssertEqual(fetched?.noteId, "note-42")
    }

    func testSessionDefaultsToNilNoteId() throws {
        let session = Session(title: "T")
        try db.database.write { try session.insert($0) }
        let fetched = try db.database.read { try Session.fetchOne($0, key: session.id) }
        XCTAssertNil(fetched?.noteId)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionNoteIdMigrationTests`
Expected: COMPILE FAIL — `Session.init` has no `noteId:` parameter.

- [ ] **Step 3: Add `noteId` to `Session`**

Edit `Scribe/Storage/Session.swift` — apply these three edits in order.

**A. Add the stored property after `var tags: [String]`:**

```swift
    /// ID of the Note this session is bound to, or nil if unattached.
    var noteId: String?
```

**B. Add `noteId` to the initializer parameter list (place after `tags`) and assign it:**

```swift
    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        language: String? = nil,
        tags: [String] = [],
        noteId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.language = language
        self.tags = tags
        self.noteId = noteId
    }
```

**C. Extend the `CodingKeys` enum and Codable conformances:**

```swift
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, endedAt, durationSeconds, language, tags, noteId
    }
```

In `init(from:)`, append after the existing `tags` decode block:

```swift
        noteId = try container.decodeIfPresent(String.self, forKey: .noteId)
```

In `encode(to:)`, append after the existing `tags` encode block:

```swift
        try container.encodeIfPresent(noteId, forKey: .noteId)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionNoteIdMigrationTests`
Expected: PASS (4 tests).

Run: `swift test`
Expected: full suite still green — `Session`'s default initializer is unchanged for existing call sites.

- [ ] **Step 5: Commit**

```bash
git add Scribe/Storage/Session.swift ScribeTests/SessionNoteIdMigrationTests.swift
git commit -m "feat(session): add optional noteId field with Codable round-trip"
```

---

### Task 15.3: `TranscriptStore` bind + observe APIs

**Files:**
- Modify: `Scribe/Storage/TranscriptStore.swift`
- Test: `ScribeTests/TranscriptStoreNoteBindingTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `ScribeTests/TranscriptStoreNoteBindingTests.swift`:

```swift
// ScribeTests/TranscriptStoreNoteBindingTests.swift
import XCTest
import Combine
@testable import Scribe

final class TranscriptStoreNoteBindingTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var transcripts: TranscriptStore!
    private var notes: NoteStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        dbm = try! DatabaseManager(path: ":memory:")
        transcripts = TranscriptStore(databaseManager: dbm)
        notes = NoteStore(databaseManager: dbm)
    }

    override func tearDown() {
        cancellables.removeAll()
        transcripts = nil
        notes = nil
        dbm = nil
    }

    func testBindSessionAttachesNoteId() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertEqual(fetched?.noteId, note.id)
    }

    func testBindSessionToNilDetaches() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)
        try transcripts.bindSession(session.id, toNote: nil)
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertNil(fetched?.noteId)
    }

    func testFetchSessionsForNoteIdOrdersByCreatedAtDesc() throws {
        let note = try notes.createNote(title: "N", body: "")
        let s1 = try transcripts.createSession(title: "First")
        // Sleep is unreliable; instead set createdAt explicitly by re-inserting.
        // We just create a second session — its createdAt will be later.
        let s2 = try transcripts.createSession(title: "Second")
        try transcripts.bindSession(s1.id, toNote: note.id)
        try transcripts.bindSession(s2.id, toNote: note.id)
        let list = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(list.map(\.id), [s2.id, s1.id])
    }

    func testFetchSessionsForNoteIdExcludesUnbound() throws {
        let note = try notes.createNote(title: "N", body: "")
        let bound = try transcripts.createSession(title: "Bound")
        _ = try transcripts.createSession(title: "Unbound")
        try transcripts.bindSession(bound.id, toNote: note.id)
        let list = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(list.map(\.id), [bound.id])
    }

    func testObserveSessionsForNoteIdEmitsOnBind() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        let expectation = self.expectation(description: "observation emits after bind")
        expectation.expectedFulfillmentCount = 2  // initial empty + post-bind

        var emissions: [[Session]] = []
        transcripts.observeSessions(forNoteId: note.id)
            .sink(receiveCompletion: { _ in },
                  receiveValue: { value in
                emissions.append(value)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        // Wait a beat for the initial emission, then bind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            try? self.transcripts.bindSession(session.id, toNote: note.id)
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(emissions.first?.count, 0)
        XCTAssertEqual(emissions.last?.count, 1)
        XCTAssertEqual(emissions.last?.first?.id, session.id)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriptStoreNoteBindingTests`
Expected: COMPILE FAIL — methods not defined.

- [ ] **Step 3: Implement the bind/fetch/observe APIs**

In `Scribe/Storage/TranscriptStore.swift`, add `import Combine` near the top if it isn't already present (it is — file already imports Combine).

Add this MARK block after the existing `// MARK: - Session CRUD` block (before segment CRUD):

```swift
    // MARK: - Note binding

    /// Binds a session to a note. Pass `nil` to detach.
    func bindSession(_ sessionId: String, toNote noteId: String?) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE sessions SET noteId = ? WHERE id = ?",
                arguments: [noteId, sessionId]
            )
        }
    }

    /// Returns all sessions bound to a note, most recent first.
    func fetchSessions(forNoteId noteId: String) throws -> [Session] {
        try db.read { database in
            try Session
                .filter(Column("noteId") == noteId)
                .order(Column("createdAt").desc)
                .fetchAll(database)
        }
    }

    /// Observes the list of sessions bound to a note. Re-emits on bind/unbind.
    func observeSessions(forNoteId noteId: String) -> AnyPublisher<[Session], Error> {
        ValueObservation
            .tracking { database in
                try Session
                    .filter(Column("noteId") == noteId)
                    .order(Column("createdAt").desc)
                    .fetchAll(database)
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriptStoreNoteBindingTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Scribe/Storage/TranscriptStore.swift ScribeTests/TranscriptStoreNoteBindingTests.swift
git commit -m "feat(transcript-store): bind/fetch/observe sessions by noteId"
```

---

### Task 15.4: `NoteStore.deleteNote` sweeps `sessions.noteId`

**Files:**
- Modify: `Scribe/Storage/NoteStore.swift`
- Test: `ScribeTests/TranscriptStoreNoteBindingTests.swift` (add case)

- [ ] **Step 1: Write the failing test**

Append to `ScribeTests/TranscriptStoreNoteBindingTests.swift`:

```swift
    func testDeleteNoteSweepsBoundSessions() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)

        try notes.deleteNote(id: note.id)

        // Session must still exist…
        XCTAssertNotNil(try transcripts.fetchSession(id: session.id))
        // …but its noteId must be cleared.
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertNil(fetched?.noteId)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptStoreNoteBindingTests.testDeleteNoteSweepsBoundSessions`
Expected: FAIL — `fetched?.noteId` is still set to `note.id`, because `deleteNote` doesn't sweep.

- [ ] **Step 3: Add the sweep**

Edit `Scribe/Storage/NoteStore.swift` — replace the existing `deleteNote(id:)` (around line 81) with:

```swift
    func deleteNote(id: String) throws {
        try db.write { database in
            // Sweep sessions.noteId → NULL so transcripts outlive their note.
            // FK is not enforced via ALTER TABLE in this codebase; this is the
            // same pattern used by deleteNotebook for notes.notebookId.
            try database.execute(
                sql: "UPDATE sessions SET noteId = NULL WHERE noteId = ?",
                arguments: [id]
            )
            _ = try Note.deleteOne(database, key: id)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TranscriptStoreNoteBindingTests`
Expected: PASS (6 tests).

Run: `swift test --filter NoteStoreTests`
Expected: PASS — existing delete-cascade tests still work.

- [ ] **Step 5: Commit**

```bash
git add Scribe/Storage/NoteStore.swift ScribeTests/TranscriptStoreNoteBindingTests.swift
git commit -m "feat(note-store): sweep sessions.noteId on deleteNote so transcripts survive"
```

---

### Slice 15 verification gate

- [ ] Run the full suite once before moving on:

```bash
swift test
```

Expected: all tests pass. If anything is red, fix before proceeding to slice 16.

---

## Slice 16 — Sessions strip in `NoteDetailView` (read-only)

A note's detail view shows linked sessions as chips with an expanded per-session auto-section sourced from existing tables. No recording entry point yet — binding happens via `bindSession` from tests or fixtures.

### Task 16.1: `NoteDetailViewModel` observes linked sessions

**Files:**
- Modify: `Scribe/UI/Notes/NoteDetailViewModel.swift`
- Test: `ScribeTests/NoteDetailViewModelTests.swift` (new)

- [ ] **Step 1: Read the current `NoteDetailViewModel`**

Read `Scribe/UI/Notes/NoteDetailViewModel.swift` end to end. You need to know the existing properties and how `markDirty` / debounced save works so the new session observation doesn't fight it.

- [ ] **Step 2: Write the failing test**

Create `ScribeTests/NoteDetailViewModelTests.swift`:

```swift
// ScribeTests/NoteDetailViewModelTests.swift
import XCTest
import Combine
@testable import Scribe

@MainActor
final class NoteDetailViewModelTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!

    override func setUp() async throws {
        try await super.setUp()
        dbm = try DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
    }

    override func tearDown() async throws {
        notes = nil
        transcripts = nil
        dbm = nil
        try await super.tearDown()
    }

    func testSessionsExposesBoundSessions() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)

        let vm = NoteDetailViewModel(
            note: note,
            noteStore: notes,
            transcriptStore: transcripts,
            onNavigate: { _ in }
        )

        // Wait for the async observation to deliver.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vm.sessions.map(\.id), [session.id])
    }

    func testSessionsEmptyWhenNoneBound() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let vm = NoteDetailViewModel(
            note: note,
            noteStore: notes,
            transcriptStore: transcripts,
            onNavigate: { _ in }
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.sessions.count, 0)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter NoteDetailViewModelTests`
Expected: COMPILE FAIL — initializer doesn't take `noteStore` / `transcriptStore`, and `sessions` doesn't exist.

- [ ] **Step 4: Update `NoteDetailViewModel`**

Edit `Scribe/UI/Notes/NoteDetailViewModel.swift`. Add `import Combine` if missing. Add the property, accept injected stores in the initializer (defaulting to `.shared`), and wire the observation. The exact shape:

```swift
@MainActor
final class NoteDetailViewModel: ObservableObject {
    // … existing properties (note, backlinks, errorMessage, etc.) …

    @Published var sessions: [Session] = []

    private let noteStore: NoteStore
    private let transcriptStore: TranscriptStore
    private var sessionsCancellable: AnyCancellable?

    init(
        note: Note,
        noteStore: NoteStore = .shared,
        transcriptStore: TranscriptStore = .shared,
        onNavigate: @escaping (String) -> Void
    ) {
        self.note = note
        self.noteStore = noteStore
        self.transcriptStore = transcriptStore
        self.onNavigate = onNavigate
        // … existing init body (load backlinks, etc.) …

        self.sessionsCancellable = transcriptStore
            .observeSessions(forNoteId: note.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] sessions in
                    self?.sessions = sessions
                }
            )
    }

    // … existing methods (markDirty, save, handleWikiLinkNavigate, etc.) …
}
```

If the existing file uses `NoteStore.shared` directly inside methods, leave those alone — only inject what `sessions` observation needs. If existing code passes `noteStore` via a different mechanism, conform to the existing style; the goal is one observation wired in the initializer.

Note: `TranscriptStore` currently has no shared singleton accessor matching `NoteStore.shared`'s `nonisolated(unsafe) static let`. Check `TranscriptStore.swift` — it already declares `nonisolated(unsafe) static let shared = TranscriptStore()` (verified in the codebase). Good.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter NoteDetailViewModelTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the full suite to catch regressions**

Run: `swift test`
Expected: all tests pass. Any caller that constructed `NoteDetailViewModel(note:onNavigate:)` keeps working because new parameters have defaults.

- [ ] **Step 7: Commit**

```bash
git add Scribe/UI/Notes/NoteDetailViewModel.swift ScribeTests/NoteDetailViewModelTests.swift
git commit -m "feat(note-vm): observe sessions bound to the open note"
```

---

### Task 16.2: `NoteSessionsStrip` view

**Files:**
- Create: `Scribe/UI/Notes/NoteSessionsStrip.swift`

- [ ] **Step 1: Build the strip**

Create `Scribe/UI/Notes/NoteSessionsStrip.swift`:

```swift
// Scribe/UI/Notes/NoteSessionsStrip.swift
import SwiftUI

/// Horizontal strip of session chips at the top of a Note detail view.
/// Tapping a chip selects it; the parent view renders the per-session
/// auto-section beneath the strip for the selected chip.
struct NoteSessionsStrip: View {
    let sessions: [Session]
    @Binding var selectedSessionId: String?
    var onStartRecording: (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(sessions) { session in
                    SessionChip(
                        session: session,
                        isSelected: session.id == selectedSessionId
                    ) {
                        if selectedSessionId == session.id {
                            selectedSessionId = nil
                        } else {
                            selectedSessionId = session.id
                        }
                    }
                }

                if let onStartRecording {
                    Button(action: onStartRecording) {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: "record.circle")
                                .imageScale(.small)
                            Text("New recording")
                                .font(.callout)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                        .background(
                            DesignTokens.Palette.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm,
                                                 style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .background(DesignTokens.Palette.surfaceSunken)
    }
}

private struct SessionChip: View {
    let session: Session
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                statusIndicator
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                isSelected
                    ? DesignTokens.Palette.surfaceElevated
                    : DesignTokens.Palette.surfaceElevated.opacity(0.6),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? DesignTokens.Palette.accent
                            : DesignTokens.Palette.cardBorder,
                        lineWidth: 1
                    )
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private var displayTitle: String {
        session.title.isEmpty ? "Untitled Session" : session.title
    }

    private var subtitle: String {
        let date = session.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let secs = session.durationSeconds {
            let mins = max(secs / 60, 1)
            return "\(date) · \(mins)m"
        }
        return date
    }

    private var statusIndicator: some View {
        Group {
            if session.endedAt == nil {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.green)
            }
        }
    }
}
```

If `DesignTokens.Palette.accent` does not exist in the design system, substitute the closest accent token (search `Scribe/UI/DesignSystem/` for "accent" — likely `Palette.tint` or `Palette.action`). Use whichever the existing chips in `Scribe/UI/Notes/` already use.

- [ ] **Step 2: Run build to verify it compiles**

Run: `swift build`
Expected: no errors. If `DesignTokens.Palette.accent` doesn't resolve, look up the actual name and replace.

- [ ] **Step 3: Commit**

```bash
git add Scribe/UI/Notes/NoteSessionsStrip.swift
git commit -m "feat(notes): NoteSessionsStrip — chip per linked session"
```

---

### Task 16.3: Inspect existing summary / action-item / entities subviews

**Files:**
- Inspect: `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift`

- [ ] **Step 1: Identify reusable subviews**

Open `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift`. Find the three computed properties:
- `summarySection`
- `actionItemsSection`
- `insightsSection`

These are private `some View` properties on `TranscriptDetailView` and read from `viewModel: TranscriptDetailViewModel`. They aren't usable from a Note context as-is.

For this slice we'll keep them in place and write a thinner per-session block in slice 16 that loads the same underlying data via `TranscriptDetailViewModel` (which already exposes `summary`, `actionItems`, `entities`).

No code change in this step — this is a read-only reconnaissance step before Task 16.4.

- [ ] **Step 2: Confirm `TranscriptDetailViewModel` is accessible**

Read `Scribe/UI/TranscriptViewer/TranscriptDetailViewModel.swift`. Verify it has:
- `var summary: MeetingSummary?` (or similar; published)
- `var actionItems: [ActionItem]` (published)
- `var entities: [ExtractedEntity]` (or similar)

Note the exact property names — Task 16.4 uses them directly. If a property is private, expose it as `@Published private(set)` rather than rewriting the view model from scratch.

- [ ] **Step 3: No commit needed for this reconnaissance step.**

---

### Task 16.4: `NoteSessionAutoSection` view (read-only)

**Files:**
- Create: `Scribe/UI/Notes/NoteSessionAutoSection.swift`
- Test: none — pure SwiftUI rendering driven by an injected view model. UI regression caught at runtime.

- [ ] **Step 1: Create the auto-section**

Create `Scribe/UI/Notes/NoteSessionAutoSection.swift`. This view owns its own `TranscriptDetailViewModel` for the given session so summary / action items / entities load and refresh independently:

```swift
// Scribe/UI/Notes/NoteSessionAutoSection.swift
import SwiftUI

/// Read-only block under a NoteSessionsStrip chip, showing the AI summary,
/// action items, and entities/topics for one bound session.
struct NoteSessionAutoSection: View {
    @StateObject private var viewModel: TranscriptDetailViewModel
    let onOpenSession: () -> Void
    let onConvertActionItem: (ActionItem) -> Void

    init(
        session: Session,
        onOpenSession: @escaping () -> Void,
        onConvertActionItem: @escaping (ActionItem) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: TranscriptDetailViewModel(session: session))
        self.onOpenSession = onOpenSession
        self.onConvertActionItem = onConvertActionItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header

            summaryBlock
            actionItemsBlock
            entitiesBlock
        }
        .padding(.horizontal, 20)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceSunken)
    }

    private var header: some View {
        HStack {
            Text("From this recording")
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open transcript", action: onOpenSession)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DesignTokens.Palette.accent)
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        if let summary = viewModel.summary {
            sectionLabel("Summary")
            Text(summary.summary)
                .font(.callout)
                .foregroundStyle(.primary)
        } else if viewModel.isSummarizing {
            sectionLabel("Summary")
            ProgressView().controlSize(.small)
        } else {
            sectionLabel("Summary")
            Button("Generate summary") {
                Task { await viewModel.summarizeMeeting() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var actionItemsBlock: some View {
        if !viewModel.actionItems.isEmpty {
            sectionLabel("Action items")
            ForEach(viewModel.actionItems) { item in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .imageScale(.small)
                        .foregroundStyle(item.isCompleted ? .green : .secondary)
                    Text(item.description)
                        .font(.callout)
                        .strikethrough(item.isCompleted)
                    Spacer()
                    Button("Convert to task") { onConvertActionItem(item) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Palette.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var entitiesBlock: some View {
        if !viewModel.entities.isEmpty {
            sectionLabel("Mentioned")
            FlowLayout(spacing: DesignTokens.Spacing.xs) {
                ForEach(viewModel.entities) { entity in
                    Text(entity.text)
                        .font(.caption)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(
                            DesignTokens.Palette.surfaceElevated,
                            in: Capsule()
                        )
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.eyebrow)
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
```

**Important compatibility checks before pasting:**
1. **`viewModel.summary` / `viewModel.actionItems` / `viewModel.entities` / `viewModel.summarizeMeeting()` / `viewModel.isSummarizing`** — the property/method names must match what `TranscriptDetailViewModel` already exposes. If a property is named differently (e.g. `summaryRecord` or `topEntities`), substitute the actual name. **Do not rename properties on `TranscriptDetailViewModel`** — adapt this view to the existing API.
2. **`FlowLayout`** — if a custom flow-layout view doesn't already exist in `Scribe/UI/DesignSystem/`, replace the `FlowLayout { … }` block with a wrapping `HStack` inside a `ScrollView(.horizontal)`:
   ```swift
   ScrollView(.horizontal, showsIndicators: false) {
       HStack(spacing: DesignTokens.Spacing.xs) {
           ForEach(viewModel.entities) { entity in
               // … same Text capsule …
           }
       }
   }
   ```
3. **`item.description`** on `ActionItem` — check `Scribe/Storage/TranscriptStore.swift` or wherever `ActionItem` is defined for the actual property (likely `description` based on the migration v2 column name). If different, match it.

- [ ] **Step 2: Run build to verify it compiles**

Run: `swift build`
Expected: no errors. Fix any mismatched property names by reading `TranscriptDetailViewModel.swift` and substituting the real names. Do not create stubs or placeholder properties.

- [ ] **Step 3: Commit**

```bash
git add Scribe/UI/Notes/NoteSessionAutoSection.swift
git commit -m "feat(notes): per-session auto-section showing summary, action items, entities"
```

---

### Task 16.5: Wire the strip + auto-section into `NoteDetailView`

**Files:**
- Modify: `Scribe/UI/Notes/NoteDetailView.swift`

- [ ] **Step 1: Add state for the selected session chip**

Open `Scribe/UI/Notes/NoteDetailView.swift`. Add a `@State` for the selected session and an action item conversion handler.

Near the existing `@State private var backlinksExpanded`:

```swift
    @State private var selectedSessionId: String? = nil
    @State private var actionItemToConvert: ActionItem? = nil
```

- [ ] **Step 2: Insert the strip and auto-section into the layout**

Locate the `body` in `NoteDetailView`. After the `Divider()` that sits below the header and before `NoteEditorView(...)`, insert:

```swift
            if !vm.sessions.isEmpty || vm.isRecordingForThisNote == false {
                // The strip stays visible whenever the note has sessions OR
                // when we want to surface "New recording" later in slice 17.
                // For slice 16, the strip is rendered only when sessions exist:
                if !vm.sessions.isEmpty {
                    NoteSessionsStrip(
                        sessions: vm.sessions,
                        selectedSessionId: $selectedSessionId,
                        onStartRecording: nil  // wired in slice 17
                    )
                    if let selectedId = selectedSessionId,
                       let session = vm.sessions.first(where: { $0.id == selectedId }) {
                        NoteSessionAutoSection(
                            session: session,
                            onOpenSession: { onNavigate(session.id) },
                            onConvertActionItem: { actionItemToConvert = $0 }
                        )
                    }
                    Divider()
                }
            }
```

Note: `vm.isRecordingForThisNote` is added in slice 17. For slice 16, simplify to just `if !vm.sessions.isEmpty { … }`. The conditional above is forward-looking; you can write the simpler version now:

```swift
            if !vm.sessions.isEmpty {
                NoteSessionsStrip(
                    sessions: vm.sessions,
                    selectedSessionId: $selectedSessionId,
                    onStartRecording: nil  // wired in slice 17
                )
                if let selectedId = selectedSessionId,
                   let session = vm.sessions.first(where: { $0.id == selectedId }) {
                    NoteSessionAutoSection(
                        session: session,
                        onOpenSession: { onNavigate(session.id) },
                        onConvertActionItem: { actionItemToConvert = $0 }
                    )
                }
                Divider()
            }
```

- [ ] **Step 3: Auto-select the first chip when sessions appear**

After the body declaration (still inside the `View`), append a modifier on the outer `VStack`:

```swift
        .onChange(of: vm.sessions) { _, newSessions in
            if selectedSessionId == nil, let first = newSessions.first {
                selectedSessionId = first.id
            } else if let id = selectedSessionId,
                      !newSessions.contains(where: { $0.id == id }) {
                selectedSessionId = newSessions.first?.id
            }
        }
```

- [ ] **Step 4: Convert-to-task plumbing**

The existing `TranscriptDetailView` uses `ActionItemConverter` (or a helper of that name in `Scribe/Tasks/` or `Scribe/Storage/`) to turn an `ActionItem` into a `TodoTask`. Grep for the symbol to find it:

```bash
grep -rn "ActionItemConverter\|convertActionItem\|convertToTask" Scribe/
```

Wire the `.sheet(item: $actionItemToConvert) { item in … }` modifier to present the existing `TaskEditorView` pre-filled from `item`, mirroring how `TranscriptDetailView` already does it. If the pattern is clearer, copy that exact sheet block from `TranscriptDetailView.swift` and adapt the binding.

- [ ] **Step 5: Regenerate the Xcode project (new files were added)**

Run: `xcodegen`
Expected: succeeds silently.

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build`
Expected: BUILD SUCCEEDED. If a property mismatch surfaces from Task 16.4, fix it now.

- [ ] **Step 7: Manual smoke test**

This is a UI change that needs a hand-check. From a SwiftPM test or directly via `lldb` (or just by editing the on-disk DB once), set `noteId` on an existing session to one of your existing notes:

```sql
-- one-shot in sqlite3 against ~/Library/Application Support/Scribe/scribe.db
-- (back up first!)
UPDATE sessions SET noteId = '<note-uuid>' WHERE id = '<session-uuid>';
```

Then launch the app, open that note, and verify:
- The Sessions strip appears under the header.
- A chip shows the session title, date, duration.
- Clicking the chip expands the auto-section with summary / action items / entities (whichever are present for that session).
- Clicking "Open transcript" navigates to the transcript detail view.

If you don't want to touch the live DB, skip this step until slice 19 ships the "Move to note…" toolbar action — Task 19.1 makes binding accessible from the UI.

- [ ] **Step 8: Commit**

```bash
git add Scribe/UI/Notes/NoteDetailView.swift
git commit -m "feat(notes): render Sessions strip and per-session auto-section in NoteDetailView"
```

---

### Slice 16 verification gate

- [ ] Run the full suite:

```bash
swift test
```

Expected: all green. UI changes don't have automated tests in this slice — the smoke test in Task 16.5 covers visual confirmation.

---

## Slice 17 — `+ New recording` from inside a Note

A button in `NoteSessionsStrip` starts a recording bound to the open note. The detail pane switches to live-recording mode for that note.

### Task 17.1: `AppState.startSession` accepts `noteId`

**Files:**
- Modify: `Scribe/App/AppState.swift`
- Test: `ScribeTests/AppStateNoteBindingTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `ScribeTests/AppStateNoteBindingTests.swift`:

```swift
// ScribeTests/AppStateNoteBindingTests.swift
import XCTest
@testable import Scribe

@MainActor
final class AppStateNoteBindingTests: XCTestCase {
    func testStartSessionBindsToProvidedNoteId() async throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let appState = await AppState(databaseManager: dbm)
        let notes = NoteStore(databaseManager: dbm)
        let transcripts = TranscriptStore(databaseManager: dbm)

        let note = try notes.createNote(title: "My note", body: "")

        // startSession boots audio — we expect it to throw because mic isn't
        // available in a test runner. That's fine: we only need the session
        // row to be inserted and bound before the audio path runs.
        do {
            try await appState.startSession(title: "Test", noteId: note.id)
        } catch {
            // ignored — audio bootstrap may fail under XCTest
        }

        // The session is created and bound BEFORE audio starts in startSession.
        let bound = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(bound.count, 1)
        XCTAssertEqual(bound.first?.title, "Test")

        // Best-effort teardown — ignore failures.
        try? await appState.stopSession()
    }
}
```

Note: `AppState.init` may not currently accept `databaseManager:`. If it doesn't, **do not modify** `AppState.init` for this test — instead replace the body with a direct verification that `TranscriptStore.bindSession` is called inline in `startSession`. The test goal is:

> When `startSession(title:noteId:)` runs, the new session row's `noteId` equals the passed-in argument.

If `AppState` is hard to stand up in isolation, write a minimal unit test that exercises only the bind path: create the session via `TranscriptStore`, call the bind method, verify. Don't go around `startSession`. The integration test in slice 18 covers the end-to-end path through `AppDelegate`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStateNoteBindingTests`
Expected: COMPILE FAIL — `startSession(title:noteId:)` doesn't exist.

- [ ] **Step 3: Add the `noteId` parameter to `AppState.startSession`**

Open `Scribe/App/AppState.swift`. Find `func startSession(title: String = "Untitled Session") async throws` (around line 302). Change the signature and body:

```swift
    func startSession(
        title: String = "Untitled Session",
        noteId: String? = nil
    ) async throws {
        // Create a persistent session.
        let session = try transcriptStore.createSession(title: title)
        currentSessionId = session.id

        // Bind to a Note immediately if requested, so the Sessions strip in
        // the open note observes the new chip from the very first frame.
        if let noteId {
            try transcriptStore.bindSession(session.id, toNote: noteId)
        }

        // … (rest of the existing body unchanged) …
    }
```

Do not change any other behaviour in `startSession`. The bind call sits between `createSession` and the audio bootstrap.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppStateNoteBindingTests`
Expected: PASS. If the test struggles with `AppState` bootstrap (audio permissions etc.), simplify to the minimal-unit form described in Step 1.

- [ ] **Step 5: Commit**

```bash
git add Scribe/App/AppState.swift ScribeTests/AppStateNoteBindingTests.swift
git commit -m "feat(app-state): startSession optionally binds to a noteId"
```

---

### Task 17.2: Wire the strip's "+ New recording" button

**Files:**
- Modify: `Scribe/UI/Notes/NoteDetailView.swift`
- Modify: `Scribe/UI/Notes/NoteDetailViewModel.swift`

- [ ] **Step 1: Find the existing global record entry point**

Read `Scribe/App/AppDelegate.swift` around line 131–140. Note how `startRecording()` is called from the toolbar / keyboard shortcut. It calls `AppState.startSession`.

Find the access path from a SwiftUI view to `AppState` and/or `AppDelegate`. It's likely a singleton (`AppState.shared`) or passed via `@EnvironmentObject`. Grep:

```bash
grep -rn "AppState.shared\|@EnvironmentObject var appState\|@EnvironmentObject private var appState" Scribe/UI/ | head -10
```

Use whichever pattern is already established.

- [ ] **Step 2: Add a `startRecording()` method to `NoteDetailViewModel`**

In `Scribe/UI/Notes/NoteDetailViewModel.swift`, add a method:

```swift
    /// Starts a new recording bound to this note. The detail pane switches into
    /// live-recording mode via observation of `AppState.isTranscribing`.
    func startRecording(appState: AppState) {
        Task {
            do {
                try await appState.startSession(title: note.title.isEmpty ? "Recording" : note.title,
                                                noteId: note.id)
            } catch {
                await MainActor.run {
                    self.errorMessage = "Couldn't start recording: \(error.localizedDescription)"
                }
            }
        }
    }
```

- [ ] **Step 3: Wire the button in `NoteDetailView`**

In `NoteDetailView`, gain access to `AppState`. If the project uses `@EnvironmentObject`:

```swift
    @EnvironmentObject private var appState: AppState
```

Replace the `onStartRecording: nil` in Task 16.5's strip wiring with:

```swift
                NoteSessionsStrip(
                    sessions: vm.sessions,
                    selectedSessionId: $selectedSessionId,
                    onStartRecording: { vm.startRecording(appState: appState) }
                )
```

Always render the strip now (not just when `vm.sessions.isEmpty == false`) so the "New recording" button is reachable from an empty note. Adjust the conditional:

```swift
            NoteSessionsStrip(
                sessions: vm.sessions,
                selectedSessionId: $selectedSessionId,
                onStartRecording: { vm.startRecording(appState: appState) }
            )
            if let selectedId = selectedSessionId,
               let session = vm.sessions.first(where: { $0.id == selectedId }) {
                NoteSessionAutoSection(
                    session: session,
                    onOpenSession: { onNavigate(session.id) },
                    onConvertActionItem: { actionItemToConvert = $0 }
                )
            }
            Divider()
```

- [ ] **Step 4: Build & manual smoke**

Run: `swift build` then `xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build`
Expected: BUILD SUCCEEDED.

Manual test: open a Note, click "New recording". Microphone permission prompt may appear (grant it). The Sessions strip should show a new chip in "recording" state (red dot). Stop via the toolbar Record button. The chip should flip to "done"; the auto-section becomes available after summarization completes.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/Notes/NoteDetailView.swift Scribe/UI/Notes/NoteDetailViewModel.swift
git commit -m "feat(notes): + New recording button binds session to open note"
```

---

### Task 17.3: Inline live-transcript pane during in-note recording

**Files:**
- Create: `Scribe/UI/Notes/NoteLiveRecordingPane.swift`
- Modify: `Scribe/UI/Notes/NoteDetailView.swift`

- [ ] **Step 1: Inspect the existing live view**

Read `Scribe/UI/MainWindow/` — the live-session view that renders when `MainSelection.live` is selected. Grep:

```bash
grep -rn "MainSelection.live\|LiveSession\|LiveTranscript" Scribe/UI/
```

Find the live view file (likely `LiveSessionView.swift` or inlined in `MainWindowView.swift`). Note what data it reads (`AppState.overlaySegments`, `AppState.pendingSegment`, `AppState.isTranscribing`, `AppState.currentSessionId`).

- [ ] **Step 2: Create `NoteLiveRecordingPane`**

Create `Scribe/UI/Notes/NoteLiveRecordingPane.swift`:

```swift
// Scribe/UI/Notes/NoteLiveRecordingPane.swift
import SwiftUI

/// Compact live-transcript readout shown inside a Note's detail view while a
/// recording bound to that note is in progress. Mirrors the standalone
/// MainSelection.live view but trimmed to fit above the freeform editor.
struct NoteLiveRecordingPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header
            transcriptScroll
        }
        .padding(.horizontal, 20)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceSunken)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(appState.overlaySegments) { segment in
                        liveLine(speaker: segment.speaker, text: segment.text)
                            .id(segment.id)
                    }
                    if let pending = appState.pendingSegment {
                        liveLine(speaker: pending.speaker, text: pending.text)
                            .foregroundStyle(.secondary)
                            .id("pending")
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            .frame(maxHeight: 160)
            .onChange(of: appState.overlaySegments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("pending", anchor: .bottom)
                }
            }
        }
    }

    private func liveLine(speaker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(speaker)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(text)
                .font(.callout)
        }
    }
}
```

**Compatibility note:** `appState.overlaySegments` and `appState.pendingSegment` are the exact property names from `Scribe/App/AppState.swift` (verified in source). `segment.speaker` and `segment.text` come from the `Segment` model — confirm in `Scribe/Storage/Segment.swift`. If `overlaySegments` is a different type than `[Segment]` (it's likely an in-memory transcript line type), match the actual element shape.

- [ ] **Step 3: Render the pane when recording belongs to this note**

In `Scribe/UI/Notes/NoteDetailView.swift`, add a derived flag in the view (or expose via the view model). Inline form:

```swift
    private var isRecordingForThisNote: Bool {
        appState.isTranscribing
            && appState.currentSessionId.flatMap { sid in
                vm.sessions.first(where: { $0.id == sid })?.id
            } != nil
    }
```

Insert the live pane right after the Sessions strip and before the auto-section:

```swift
            NoteSessionsStrip(
                sessions: vm.sessions,
                selectedSessionId: $selectedSessionId,
                onStartRecording: { vm.startRecording(appState: appState) }
            )
            if isRecordingForThisNote {
                NoteLiveRecordingPane()
            }
            if let selectedId = selectedSessionId,
               let session = vm.sessions.first(where: { $0.id == selectedId }) {
                NoteSessionAutoSection(
                    session: session,
                    onOpenSession: { onNavigate(session.id) },
                    onConvertActionItem: { actionItemToConvert = $0 }
                )
            }
            Divider()
```

- [ ] **Step 4: Regenerate Xcode project and build**

```bash
xcodegen
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke test**

Open a Note. Click "New recording". Verify:
- A live pane appears under the strip with a red dot and "Recording" label.
- Speaking into the mic produces lines in the pane within a couple of seconds.
- Stopping (toolbar Record button) hides the live pane and reveals the auto-section once summarisation completes.

- [ ] **Step 6: Commit**

```bash
git add Scribe/UI/Notes/NoteLiveRecordingPane.swift Scribe/UI/Notes/NoteDetailView.swift
git commit -m "feat(notes): show live transcript inline while recording bound to the note"
```

---

### Slice 17 verification gate

- [ ] Full suite:

```bash
swift test
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build
```

Both green. Manual flow verified end-to-end (start, type during recording, stop, auto-section populates).

---

## Slice 18 — Global Record auto-binds to open Note

The hero record button and `⇧⌘R` shortcut learn that Notes exist. With a Note open, the new session binds to it. Otherwise a "Meeting on …" Note is auto-created.

### Task 18.1: Expose current selection to `AppDelegate`

**Files:**
- Modify: `Scribe/UI/MainWindow/MainWindowView.swift`
- Modify: `Scribe/App/AppDelegate.swift`

- [ ] **Step 1: Inspect selection ownership**

Read `Scribe/UI/MainWindow/MainWindowView.swift`. `@State private var selection: MainSelection?` lives in `MainWindowView`. `AppDelegate` doesn't read it today.

We need `AppDelegate.startRecording()` to know the current selection so it can decide whether to use the open Note's id or to create a fresh Note.

**Approach:** add a `nonisolated(unsafe) static var currentSelection: MainSelection?` on `AppState` (or on `MainWindowView`) updated via `.onChange(of: selection)` in `MainWindowView`. `AppDelegate.startRecording()` reads it.

- [ ] **Step 2: Add the selection-pointer property**

In `Scribe/App/AppState.swift` (it's the obvious shared cross-cutting singleton already used elsewhere), add a published or `@MainActor` property:

```swift
    /// The current sidebar selection in MainWindowView. Updated by the view on
    /// every selection change. AppDelegate reads it when deciding how to handle
    /// a global Record action.
    @Published var currentSelection: MainSelection?
```

- [ ] **Step 3: Write to it from `MainWindowView`**

In `Scribe/UI/MainWindow/MainWindowView.swift`, add an `.onChange(of: selection)` modifier on the `NavigationSplitView` (or wherever the root view lives):

```swift
        .onChange(of: selection) { _, newValue in
            appState.currentSelection = newValue
        }
```

If `MainWindowView` already has `@EnvironmentObject private var appState: AppState`, reuse it. Otherwise look up how `MainWindowView` accesses AppState today (the existing toolbar Record button calls into it — see `HeroRecordButton(isRecording: isRecording, action: onRecord)`; the `onRecord` callback is plumbed in by the parent. Trace the plumbing to find the AppState handle.)

- [ ] **Step 4: No test for this glue (UI-only)**

This step is pure UI plumbing — no automated test. Verify the next task's behaviour-level test passes after this is wired.

- [ ] **Step 5: Commit**

```bash
git add Scribe/App/AppState.swift Scribe/UI/MainWindow/MainWindowView.swift
git commit -m "chore(app-state): expose currentSelection for AppDelegate to read"
```

---

### Task 18.2: `AppDelegate.startRecording()` resolves note context

**Files:**
- Modify: `Scribe/App/AppDelegate.swift`
- Test: `ScribeTests/AppStateNoteBindingTests.swift` (add case)

- [ ] **Step 1: Write the failing test**

Append to `ScribeTests/AppStateNoteBindingTests.swift`:

```swift
    func testGlobalRecordAutoCreatesNoteWhenNoSelection() async throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let appState = await AppState(databaseManager: dbm)
        let notes = NoteStore(databaseManager: dbm)
        let transcripts = TranscriptStore(databaseManager: dbm)

        await MainActor.run { appState.currentSelection = nil }

        // Direct invocation of the resolution helper. AppDelegate.startRecording
        // wraps audio bootstrap; we only verify the *resolution* output.
        let resolved = await AppDelegate.resolveNoteContext(
            selection: appState.currentSelection,
            noteStore: notes,
            now: Date(timeIntervalSince1970: 1_715_000_000)  // fixed for assertion
        )

        XCTAssertNotNil(resolved.noteId)
        let createdNote = try notes.fetchNote(id: resolved.noteId!)
        XCTAssertTrue(createdNote!.title.hasPrefix("Meeting on"))
        XCTAssertEqual(resolved.didCreateNote, true)
    }

    func testGlobalRecordUsesNoteWhenNoteIsSelected() async throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let appState = await AppState(databaseManager: dbm)
        let notes = NoteStore(databaseManager: dbm)

        let note = try notes.createNote(title: "Existing", body: "")
        await MainActor.run { appState.currentSelection = .note(note.id) }

        let resolved = await AppDelegate.resolveNoteContext(
            selection: appState.currentSelection,
            noteStore: notes,
            now: Date()
        )

        XCTAssertEqual(resolved.noteId, note.id)
        XCTAssertEqual(resolved.didCreateNote, false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStateNoteBindingTests`
Expected: COMPILE FAIL — `AppDelegate.resolveNoteContext` doesn't exist.

- [ ] **Step 3: Add the resolver to `AppDelegate`**

In `Scribe/App/AppDelegate.swift`, add a static helper above `startRecording`:

```swift
extension AppDelegate {
    struct ResolvedNoteContext {
        let noteId: String?
        let didCreateNote: Bool
    }

    /// Pure resolver: decides which Note a new global recording should be
    /// bound to, creating a "Meeting on <datetime>" Note if necessary.
    /// Extracted as a static helper so it's unit-testable without booting
    /// audio.
    static func resolveNoteContext(
        selection: MainSelection?,
        noteStore: NoteStore,
        now: Date
    ) async -> ResolvedNoteContext {
        if case .note(let noteId)? = selection {
            return ResolvedNoteContext(noteId: noteId, didCreateNote: false)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let title = "Meeting on \(formatter.string(from: now))"
        do {
            let created = try noteStore.createNote(title: title, body: "")
            return ResolvedNoteContext(noteId: created.id, didCreateNote: true)
        } catch {
            Log.app.error("Failed to auto-create meeting note: \(String(describing: error), privacy: .public)")
            return ResolvedNoteContext(noteId: nil, didCreateNote: false)
        }
    }
}
```

- [ ] **Step 4: Plumb the resolver into the real `startRecording`**

In `AppDelegate.startRecording()` (around line 136), before the existing call to `appState.startSession()`, resolve the note and pass it through. Find this block:

```swift
            try await appState.startSession()
```

Replace it with:

```swift
            let resolved = await Self.resolveNoteContext(
                selection: appState.currentSelection,
                noteStore: .shared,
                now: Date()
            )
            try await appState.startSession(noteId: resolved.noteId)
            if resolved.didCreateNote, let id = resolved.noteId {
                // Switch the sidebar to the new note so the live pane lives
                // inside its detail view from the very next frame.
                await MainActor.run {
                    appState.currentSelection = .note(id)
                    NotificationCenter.default.post(
                        name: .scribeRequestNavigateToNote,
                        object: nil,
                        userInfo: ["noteId": id]
                    )
                }
            }
```

Add the notification name in `Scribe/UI/MainWindow/MainWindowView.swift` alongside existing names:

```swift
extension Notification.Name {
    static let scribeRequestNavigateToNote = Notification.Name("scribeRequestNavigateToNote")
}
```

(Place near existing `extension Notification.Name` block — file already has one.)

In `MainWindowView`, subscribe and update `selection`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .scribeRequestNavigateToNote)) { note in
            if let id = note.userInfo?["noteId"] as? String {
                selection = .note(id)
            }
        }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter AppStateNoteBindingTests`
Expected: PASS (4 tests total in this file).

Run: `swift test`
Expected: full suite green.

- [ ] **Step 6: Manual smoke test**

1. With a Note open, press the toolbar Record button. The chip appears in the Sessions strip; the live pane shows.
2. From the transcript list (no note selected), press `⇧⌘R`. A new "Meeting on …" Note opens; recording is in progress; live pane shows.

- [ ] **Step 7: Commit**

```bash
git add Scribe/App/AppDelegate.swift Scribe/UI/MainWindow/MainWindowView.swift ScribeTests/AppStateNoteBindingTests.swift
git commit -m "feat(record): global Record auto-binds to open note or creates one"
```

---

### Slice 18 verification gate

- [ ] Full suite + manual flow:

```bash
swift test
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build
```

Both green. Confirm both global-record paths (note selected vs. nothing selected) end in a note with the new session bound.

---

## Slice 19 — Retrofit & export tail

Existing transcripts can be bound to a note retroactively. Markdown export of a note appends a "Linked recordings" section with summaries and action items.

### Task 19.1: "Move to note…" toolbar action on `TranscriptDetailView`

**Files:**
- Modify: `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift`
- Modify: `Scribe/UI/TranscriptViewer/TranscriptDetailViewModel.swift`
- Create: `Scribe/UI/TranscriptViewer/MoveToNotePicker.swift`
- Test: `ScribeTests/TranscriptStoreNoteBindingTests.swift` (already covers `bindSession`; verify the picker delegates correctly via a small view-model test)

- [ ] **Step 1: Picker view**

Create `Scribe/UI/TranscriptViewer/MoveToNotePicker.swift`:

```swift
// Scribe/UI/TranscriptViewer/MoveToNotePicker.swift
import SwiftUI
import Combine

struct MoveToNotePicker: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void
    let onCreateNew: () -> Void

    @State private var notes: [Note] = []
    @State private var notesCancellable: AnyCancellable?
    @State private var query: String = ""

    private var filtered: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                List {
                    Button(action: {
                        onCreateNew()
                        dismiss()
                    }) {
                        Label("New note from this session", systemImage: "plus.circle")
                    }

                    Section("Existing notes") {
                        ForEach(filtered) { note in
                            Button(action: {
                                onSelect(note.id)
                                dismiss()
                            }) {
                                Text(note.title.isEmpty ? "(Untitled)" : note.title)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle("Move to Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                notes = (try? NoteStore.shared.fetchAllNotes()) ?? []
                notesCancellable = NoteStore.shared.observeNotes()
                    .sink(receiveCompletion: { _ in },
                          receiveValue: { notes = $0 })
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }
}
```

- [ ] **Step 2: Add a "Move to note…" menu to the transcript toolbar**

In `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift`, find the toolbar block (search for `.toolbar` in the file). Add a menu item alongside existing actions:

```swift
                Menu {
                    Button("New note from this session") {
                        viewModel.moveToNewNote()
                    }
                    Button("Existing note…") {
                        showMoveToNoteSheet = true
                    }
                    if viewModel.session.noteId != nil {
                        Divider()
                        Button("Unbind from note", role: .destructive) {
                            viewModel.unbindFromNote()
                        }
                    }
                } label: {
                    Label("Move to note", systemImage: "note.text.badge.plus")
                }
```

Add the state at the top of the view alongside other `@State`s:

```swift
    @State private var showMoveToNoteSheet: Bool = false
```

Add a sheet modifier alongside the existing sheets at the end of `body`:

```swift
        .sheet(isPresented: $showMoveToNoteSheet) {
            MoveToNotePicker(
                onSelect: { noteId in viewModel.bindToNote(noteId: noteId) },
                onCreateNew: { viewModel.moveToNewNote() }
            )
        }
```

- [ ] **Step 3: Add the three view-model methods**

In `Scribe/UI/TranscriptViewer/TranscriptDetailViewModel.swift`, add:

```swift
    func bindToNote(noteId: String?) {
        do {
            try TranscriptStore.shared.bindSession(session.id, toNote: noteId)
            // Refresh local state so the toolbar menu's `session.noteId` reads
            // current.
            if let fresh = try TranscriptStore.shared.fetchSession(id: session.id) {
                self.session = fresh
            }
        } catch {
            Log.app.error("bindToNote failed: \(String(describing: error), privacy: .public)")
        }
    }

    func unbindFromNote() {
        bindToNote(noteId: nil)
    }

    func moveToNewNote() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let title = session.title.isEmpty
            ? "Notes — Meeting on \(formatter.string(from: session.createdAt))"
            : "Notes — \(session.title)"
        do {
            let note = try NoteStore.shared.createNote(title: title, body: "")
            bindToNote(noteId: note.id)
            // Tell the main window to navigate to the new note.
            NotificationCenter.default.post(
                name: .scribeRequestNavigateToNote,
                object: nil,
                userInfo: ["noteId": note.id]
            )
        } catch {
            Log.app.error("moveToNewNote failed: \(String(describing: error), privacy: .public)")
        }
    }
```

If `session` is `let` on the view model rather than `var`, change it to `@Published var session: Session`.

In step 2 (`TranscriptDetailView` toolbar), update the call site for the "Existing note…" sheet to pass an optional:

```swift
        .sheet(isPresented: $showMoveToNoteSheet) {
            MoveToNotePicker(
                onSelect: { noteId in viewModel.bindToNote(noteId: noteId) },
                onCreateNew: { viewModel.moveToNewNote() }
            )
        }
```

`MoveToNotePicker.onSelect` passes a non-optional `String`; the view model's `bindToNote(noteId:)` accepts `String?` and `String` will implicitly bridge. The user gets to `unbindFromNote()` only via the dedicated menu item.

- [ ] **Step 4: Build & manual test**

```bash
xcodegen
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build
```

Manual: open an old transcript (one that predates slice 15). Toolbar shows "Move to note". Pick "New note from this session" → the new note opens, the transcript chip is in its Sessions strip. Go back to the transcript view — the menu now offers "Unbind from note". Click it → the chip disappears from the note.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/TranscriptViewer/TranscriptDetailView.swift Scribe/UI/TranscriptViewer/TranscriptDetailViewModel.swift Scribe/UI/TranscriptViewer/MoveToNotePicker.swift
git commit -m "feat(transcripts): Move-to-note toolbar menu binds existing sessions to notes"
```

---

### Task 19.2: Markdown export appends linked recordings

**Files:**
- Modify: `Scribe/Export/` markdown exporter (find via grep below)
- Test: `ScribeTests/ExportIntegrationTests.swift` (add case)

- [ ] **Step 1: Locate the note export path**

```bash
grep -rn "func export\|MarkdownExport\|class.*Export\|exportMarkdown" Scribe/Export/
```

Identify the function that turns a `Note` into a markdown string. If notes don't have an exporter yet, this task can be skipped — the existing exporters cover sessions only. In that case, file a follow-up TODO note in `PLAN.md` and commit nothing else for 19.2.

- [ ] **Step 2: Append a "Linked recordings" tail (only if note export exists)**

For each session in `TranscriptStore.shared.fetchSessions(forNoteId: note.id)`, append:

```markdown
## Linked recordings

### {session.title} — {formatted date}

**Summary**
{summary.summary}

**Action items**
- [ ] {action.description}{ "" if no assignee else " (assignee: " + action.assignee + ")"}

**Mentioned**
- {entity.text}
```

Use string interpolation, not templating. Match the markdown style of existing exporters (look at the session exporter for cadence). Keep the section out when there are zero sessions.

- [ ] **Step 3: Write a test asserting the tail appears**

In `ScribeTests/ExportIntegrationTests.swift`, add a case (only if step 1 found a note exporter):

```swift
    func testNoteMarkdownExportIncludesLinkedRecordings() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let transcripts = TranscriptStore(databaseManager: dbm)

        let note = try notes.createNote(title: "Standup", body: "My takeaways…")
        let session = try transcripts.createSession(title: "Standup recording")
        try transcripts.bindSession(session.id, toNote: note.id)

        // For the assertion we just need a session bound; summary/action-item
        // population is exercised elsewhere.
        let markdown = /* call the actual exporter you found in step 1 */ ""
        XCTAssertTrue(markdown.contains("My takeaways"))
        XCTAssertTrue(markdown.contains("Linked recordings"))
        XCTAssertTrue(markdown.contains("Standup recording"))
    }
```

Fill in the exporter call with the actual API name (e.g. `MarkdownExporter().export(note: note)`).

- [ ] **Step 4: Run tests**

```bash
swift test --filter ExportIntegrationTests
```

Expected: PASS (or skip if no note exporter exists).

- [ ] **Step 5: Commit**

```bash
git add Scribe/Export/<file>.swift ScribeTests/ExportIntegrationTests.swift
git commit -m "feat(export): note markdown export appends linked recordings tail"
```

---

### Slice 19 verification gate

- [ ] Final full-suite run:

```bash
swift test
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build
```

Both green. Manual:
1. Bind an old transcript to a new note via "Move to note…".
2. Press global Record from inside a note — chip appears in that note.
3. Press global Record from elsewhere — new "Meeting on …" note opens.
4. (If 19.2 shipped) Export a note as markdown — linked recordings tail is present.

---

## Update PLAN.md

After all slices ship, append to the **Phase 2** or **Phase 3** section of `PLAN.md`:

- [ ] **Step 1: Append slice rows**

Add to `PLAN.md` (under "Phase 3 — Cross-linking"):

```markdown
- [x] **Slice 15 — Session ↔ Note storage.** Migration `v10_session_noteId`,
      `Session.noteId`, `TranscriptStore.bindSession/fetchSessions/observeSessions(forNoteId:)`,
      `NoteStore.deleteNote` sweeps sessions. Tests in `SessionNoteIdMigrationTests`
      and `TranscriptStoreNoteBindingTests`.
- [x] **Slice 16 — Sessions strip (read-only).** `NoteSessionsStrip` chips +
      `NoteSessionAutoSection` per-session block in `NoteDetailView`. Reuses
      `TranscriptDetailViewModel` for summary/action-items/entities.
- [x] **Slice 17 — In-note recording.** `+ New recording` button binds the new
      session to the open note; `NoteLiveRecordingPane` shows the live transcript
      inline above the freeform editor.
- [x] **Slice 18 — Global Record auto-binds.** `AppDelegate.startRecording`
      reads `AppState.currentSelection`. With a note open, binds to it; otherwise
      auto-creates a "Meeting on …" note and switches the sidebar to it.
- [x] **Slice 19 — Retrofit & export tail.** "Move to note…" toolbar action on
      transcript detail; markdown export tail for notes with linked recordings.
```

- [ ] **Step 2: Commit**

```bash
git add PLAN.md
git commit -m "docs(plan): mark Phase 3 Slices 15–19 complete"
```

---

## Self-review checklist (run after the plan is read but before execution)

- [ ] Spec coverage: every section in `docs/superpowers/specs/2026-05-15-meeting-notes-design.md` maps to at least one task.
- [ ] No placeholders: search the plan for `TBD`, `TODO`, `fill in`, `appropriate error handling`, `similar to`. Fix if found.
- [ ] Type consistency: `bindSession(_:toNote:)`, `fetchSessions(forNoteId:)`, `observeSessions(forNoteId:)`, `Session.noteId`, `resolveNoteContext`, `ResolvedNoteContext`, `NoteSessionsStrip`, `NoteSessionAutoSection`, `NoteLiveRecordingPane`, `MoveToNotePicker`, `scribeRequestNavigateToNote` — names match across tasks.
- [ ] FK pattern: confirmed `ALTER TABLE` cannot enforce FKs in this codebase; sweep handled in `NoteStore.deleteNote`.
- [ ] Migration name: `v10_session_noteId` does not collide with any existing registered migration in `DatabaseManager.swift`.

If a step contradicts what the codebase actually exposes (property names on `TranscriptDetailViewModel`, the way `AppState` is constructed in tests, the existing `Segment` shape), follow the codebase — do not invent new types just to match this plan.
