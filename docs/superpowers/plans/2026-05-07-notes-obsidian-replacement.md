# Notes (Obsidian Replacement) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class notes layer to Scribe (slices 9–14) with a markdown editor, wiki-links, backlinks, daily notes, universal search, and a force-directed graph view.

**Architecture:** `NoteStore` (SQLite/GRDB, migration v6) mirrors `TaskStore`. `MarkdownEditorView` moves to `DesignSystem/` and gains an `extraHighlighter` hook that `NoteEditorView` uses to tint `[[...]]` spans. `MainWindowView.MainSelection` gains `.note(id:)` and `.notes(NotesFilter)` cases; the sidebar gains a collapsible "Notes" section.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSTextView`), GRDB.swift, `swift test` for all unit tests (no Xcode scheme).

---

## File Map

### New files
| Path | Responsibility |
|------|---------------|
| `Scribe/Storage/Note.swift` | `Note`, `NoteLinkRow`, `NoteTagRow` GRDB models |
| `Scribe/Storage/NoteStore.swift` | CRUD, observation, daily notes, backlinks, tags, search, wiki-link parsing |
| `Scribe/UI/Notes/NoteListView.swift` | List of all notes with search field |
| `Scribe/UI/Notes/NoteListViewModel.swift` | `@MainActor ObservableObject` driving `NoteListView` |
| `Scribe/UI/Notes/NoteDetailView.swift` | Split: editor (left) + backlinks panel (right) |
| `Scribe/UI/Notes/NoteDetailViewModel.swift` | Save/discard, wiki-link navigation |
| `Scribe/UI/Notes/NoteEditorView.swift` | Wraps `MarkdownEditorView` + `[[...]]` highlight + autocomplete popup |
| `Scribe/UI/Notes/NoteBacklinksView.swift` | Right-panel list of notes that link here |
| `Scribe/UI/Notes/DailyNoteView.swift` | Thin wrapper creating/loading today's note |
| `Scribe/UI/Notes/NoteCalendarView.swift` | Month grid; dots on days with daily notes |
| `Scribe/UI/Notes/UniversalSearchView.swift` | Floating search palette (Cmd-Shift-F) |
| `Scribe/UI/Notes/UniversalSearchViewModel.swift` | Fans out to NoteStore + TaskStore + TranscriptStore |
| `Scribe/UI/Notes/GraphView.swift` | SwiftUI `Canvas` force-directed graph |
| `Scribe/UI/Notes/GraphViewModel.swift` | Node/edge data, Euler physics tick |
| `ScribeTests/NoteStoreTests.swift` | Unit tests for NoteStore (all slices) |
| `ScribeTests/WikiLinkParserTests.swift` | Unit tests for wiki-link parse + resolve |
| `ScribeTests/DailyNoteTests.swift` | Daily note idempotency + title format |
| `ScribeTests/UniversalSearchTests.swift` | Multi-store search grouping |
| `ScribeTests/GraphViewModelTests.swift` | Node/edge construction from mock data |

### Moved
| From | To | Reason |
|------|----|--------|
| `Scribe/UI/Tasks/MarkdownEditorView.swift` | `Scribe/UI/DesignSystem/MarkdownEditorView.swift` | Shared base for Notes editor |

### Modified
| Path | Change |
|------|--------|
| `Scribe/Storage/DatabaseManager.swift` | Add migration v6 (notes, note_tags, note_links, notes_fts) |
| `Scribe/UI/MainWindow/MainWindowView.swift` | Add `NotesFilter`, extend `MainSelection`, add Notes sidebar section, universal search overlay |

---

## Task 1: Note models + migration v6

**Files:**
- Create: `Scribe/Storage/Note.swift`
- Create: `ScribeTests/NoteStoreTests.swift`
- Modify: `Scribe/Storage/DatabaseManager.swift`

- [ ] **Step 1: Create `Note.swift`**

```swift
// Scribe/Storage/Note.swift
import Foundation
import GRDB

struct Note: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isDailyNote: Bool
    var dailyDate: String?  // "YYYY-MM-DD", only set when isDailyNote == true

    init(
        id: String = UUID().uuidString,
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDailyNote: Bool = false,
        dailyDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDailyNote = isDailyNote
        self.dailyDate = dailyDate
    }
}

extension Note: FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"
}

struct NoteLinkRow: Codable, Equatable, Hashable {
    var sourceNoteId: String
    var targetNoteId: String
    var anchorText: String
}

extension NoteLinkRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_links"
}

struct NoteTagRow: Codable, Equatable, Hashable {
    var noteId: String
    var tag: String
}

extension NoteTagRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_tags"
}
```

- [ ] **Step 2: Add migration v6 to `DatabaseManager.swift`**

After the closing brace of the `v5` migration block (line ~257) and before `try migrator.migrate(database)`:

```swift
        migrator.registerMigration("v6") { db in
            // -- notes --
            try db.create(table: "notes") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("body", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDailyNote", .boolean).notNull().defaults(to: false)
                t.column("dailyDate", .text)
            }
            try db.create(index: "notes_dailyDate_idx", on: "notes", columns: ["dailyDate"])
            try db.create(index: "notes_updatedAt_idx", on: "notes", columns: ["updatedAt"])

            // -- note_tags --
            try db.create(table: "note_tags") { t in
                t.column("noteId", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["noteId", "tag"])
            }
            try db.create(index: "note_tags_tag_idx", on: "note_tags", columns: ["tag"])

            // -- note_links --
            try db.create(table: "note_links") { t in
                t.column("sourceNoteId", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("targetNoteId", .text).notNull()
                    .references("notes", onDelete: .cascade)
                t.column("anchorText", .text).notNull()
                t.primaryKey(["sourceNoteId", "targetNoteId", "anchorText"])
            }
            try db.create(index: "note_links_targetNoteId_idx",
                          on: "note_links", columns: ["targetNoteId"])

            // -- notes_fts --
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    title,
                    body,
                    content='notes',
                    content_rowid='rowid'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
                    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
                    INSERT INTO notes_fts(notes_fts, rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
                    INSERT INTO notes_fts(notes_fts, rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END
                """)
        }
```

- [ ] **Step 3: Write failing tests for Note persistence**

Create `ScribeTests/NoteStoreTests.swift`:

```swift
// ScribeTests/NoteStoreTests.swift
import XCTest
import GRDB
@testable import Scribe

final class NoteStoreTests: XCTestCase {
    private var db: DatabaseManager!
    private var store: NoteStore!

    override func setUp() throws {
        db = try DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: db)
    }

    override func tearDown() { db = nil; store = nil }

    func testCreateAndFetchNote() throws {
        let note = try store.createNote(title: "Hello", body: "World", tags: [])
        let fetched = try store.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.title, "Hello")
        XCTAssertEqual(fetched?.body, "World")
        XCTAssertFalse(fetched!.isDailyNote)
    }

    func testUpdateNote() throws {
        var note = try store.createNote(title: "Old", body: "", tags: [])
        note.title = "New"
        note.body = "Updated body"
        try store.updateNote(note, tags: [])
        let fetched = try store.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.title, "New")
        XCTAssertEqual(fetched?.body, "Updated body")
    }

    func testDeleteNote() throws {
        let note = try store.createNote(title: "Delete me", body: "", tags: [])
        try store.deleteNote(id: note.id)
        XCTAssertNil(try store.fetchNote(id: note.id))
    }

    func testTagsRoundTrip() throws {
        let note = try store.createNote(title: "Tagged", body: "", tags: ["Swift", " iOS "])
        let tags = try store.tags(for: note.id)
        XCTAssertEqual(Set(tags), Set(["swift", "ios"]))  // normalized: trimmed + lowercased
    }

    func testDeleteCascadesCleansTagsAndLinks() throws {
        let a = try store.createNote(title: "A", body: "[[B]]", tags: ["x"])
        let b = try store.createNote(title: "B", body: "", tags: [])
        try store.updateNote(a, tags: ["x"])  // triggers link parse
        try store.deleteNote(id: a.id)
        let linksAfter = try store.backlinks(for: b.id)
        XCTAssertTrue(linksAfter.isEmpty)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail (NoteStore doesn't exist yet)**

```bash
swift test --filter NoteStoreTests 2>&1 | head -20
```

Expected: compile error — `NoteStore` not found.

- [ ] **Step 5: Commit models + migration**

```bash
git add Scribe/Storage/Note.swift Scribe/Storage/DatabaseManager.swift ScribeTests/NoteStoreTests.swift
git commit -m "feat(notes): Note models + migration v6 (notes, note_tags, note_links, notes_fts)"
```

---

## Task 2: NoteStore CRUD + daily notes

**Files:**
- Create: `Scribe/Storage/NoteStore.swift`

- [ ] **Step 1: Create `NoteStore.swift` with CRUD + daily notes**

```swift
// Scribe/Storage/NoteStore.swift
import Foundation
import GRDB
import Combine

final class NoteStore {

    private let dbManager: DatabaseManager
    private var db: DatabaseQueue { dbManager.database }

    static let shared = NoteStore(databaseManager: .shared)

    init(databaseManager: DatabaseManager = .shared) {
        self.dbManager = databaseManager
    }

    // MARK: - CRUD

    @discardableResult
    func createNote(title: String, body: String = "", tags: [String] = [],
                    isDailyNote: Bool = false, dailyDate: String? = nil) throws -> Note {
        try db.write { database in
            let note = Note(title: title, body: body,
                            isDailyNote: isDailyNote, dailyDate: dailyDate)
            try note.insert(database)
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }
            return note
        }
    }

    func updateNote(_ note: Note, tags: [String]) throws {
        try db.write { database in
            var mutable = note
            mutable.updatedAt = Date()
            try mutable.update(database)

            // rewrite tags
            try database.execute(sql: "DELETE FROM note_tags WHERE noteId = ?",
                                 arguments: [note.id])
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }

            // rewrite wiki-links
            let anchors = Self.parseWikiLinks(from: note.body)
            try database.execute(sql: "DELETE FROM note_links WHERE sourceNoteId = ?",
                                 arguments: [note.id])
            for anchor in anchors {
                if let target = try Note
                    .filter(sql: "LOWER(title) = LOWER(?)", arguments: [anchor])
                    .fetchOne(database) {
                    let link = NoteLinkRow(sourceNoteId: note.id,
                                          targetNoteId: target.id,
                                          anchorText: anchor)
                    try link.insertIgnore(database)
                }
            }
        }
    }

    func deleteNote(id: String) throws {
        try db.write { _ = try Note.deleteOne($0, key: id) }
    }

    func fetchNote(id: String) throws -> Note? {
        try db.read { try Note.fetchOne($0, key: id) }
    }

    func fetchAllNotes() throws -> [Note] {
        try db.read { try Note.order(Column("updatedAt").desc).fetchAll($0) }
    }

    // MARK: - Daily notes

    private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dailyTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    func dailyNote(for date: Date) throws -> Note {
        let key = Self.dailyDateFormatter.string(from: date)
        if let existing = try db.read({ try Note
            .filter(sql: "dailyDate = ?", arguments: [key])
            .fetchOne($0) }) {
            return existing
        }
        let title = "Daily Note – \(Self.dailyTitleFormatter.string(from: date))"
        return try createNote(title: title, isDailyNote: true, dailyDate: key)
    }

    // MARK: - Tags

    func tags(for noteId: String) throws -> [String] {
        try db.read { database in
            try NoteTagRow
                .filter(Column("noteId") == noteId)
                .fetchAll(database)
                .map(\.tag)
        }
    }

    func allNoteTags() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database, sql: "SELECT DISTINCT tag FROM note_tags ORDER BY tag")
        }
    }

    // MARK: - Backlinks

    func backlinks(for noteId: String) throws -> [Note] {
        try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN note_links ON notes.id = note_links.sourceNoteId
                WHERE note_links.targetNoteId = ?
                ORDER BY notes.updatedAt DESC
                """, arguments: [noteId])
        }
    }

    // MARK: - Resolution

    func resolveTitle(_ title: String) throws -> Note? {
        try db.read { database in
            try Note.filter(sql: "LOWER(title) = LOWER(?)", arguments: [title]).fetchOne(database)
        }
    }

    // MARK: - Search

    func searchNotes(query: String) throws -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try fetchAllNotes() }
        return try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN notes_fts ON notes.rowid = notes_fts.rowid
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts)
                LIMIT 100
                """, arguments: [q + "*"])
        }
    }

    // MARK: - Observation

    func observeNotes() -> AnyPublisher<[Note], Error> {
        ValueObservation
            .tracking { try Note.order(Column("updatedAt").desc).fetchAll($0) }
            .publisher(in: db, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    // MARK: - Private helpers

    static func normalizeTags(_ tags: [String]) -> [String] {
        tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func parseWikiLinks(from text: String) -> [String] {
        let pattern = #"\[\[([^\[\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }
}
```

- [ ] **Step 2: Run CRUD tests**

```bash
swift test --filter NoteStoreTests 2>&1 | tail -20
```

Expected: all 5 tests pass.

- [ ] **Step 3: Add more NoteStore tests to `NoteStoreTests.swift`**

Append to the `NoteStoreTests` class:

```swift
    func testDailyNoteIdempotent() throws {
        let today = Date()
        let first = try store.dailyNote(for: today)
        let second = try store.dailyNote(for: today)
        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(first.isDailyNote)
        XCTAssertTrue(first.title.hasPrefix("Daily Note –"))
    }

    func testDailyNoteDifferentDatesAreDifferent() throws {
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let a = try store.dailyNote(for: today)
        let b = try store.dailyNote(for: tomorrow)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testFTSSearch() throws {
        _ = try store.createNote(title: "Swift concurrency", body: "actors and tasks", tags: [])
        _ = try store.createNote(title: "Python guide", body: "no concurrency here", tags: [])
        let results = try store.searchNotes(query: "concurr")
        XCTAssertEqual(results.count, 2)
    }

    func testFTSSearchEmptyQueryReturnsAll() throws {
        _ = try store.createNote(title: "A", body: "", tags: [])
        _ = try store.createNote(title: "B", body: "", tags: [])
        let results = try store.searchNotes(query: "")
        XCTAssertEqual(results.count, 2)
    }

    func testBacklinks() throws {
        let target = try store.createNote(title: "Target", body: "", tags: [])
        var source = try store.createNote(title: "Source", body: "See [[Target]] for details", tags: [])
        try store.updateNote(source, tags: [])
        let links = try store.backlinks(for: target.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].id, source.id)
    }

    func testAllNoteTags() throws {
        _ = try store.createNote(title: "A", body: "", tags: ["swift", "ios"])
        _ = try store.createNote(title: "B", body: "", tags: ["swift", "macos"])
        let tags = try store.allNoteTags()
        XCTAssertEqual(Set(tags), Set(["swift", "ios", "macos"]))
    }
```

- [ ] **Step 4: Run all NoteStore tests**

```bash
swift test --filter NoteStoreTests 2>&1 | tail -20
```

Expected: 11 tests pass.

- [ ] **Step 5: Commit NoteStore**

```bash
git add Scribe/Storage/NoteStore.swift ScribeTests/NoteStoreTests.swift
git commit -m "feat(notes): NoteStore CRUD, daily notes, tags, backlinks, FTS search"
```

---

## Task 3: WikiLink parser tests

**Files:**
- Create: `ScribeTests/WikiLinkParserTests.swift`

- [ ] **Step 1: Write tests for `NoteStore.parseWikiLinks`**

```swift
// ScribeTests/WikiLinkParserTests.swift
import XCTest
@testable import Scribe

final class WikiLinkParserTests: XCTestCase {

    func testParsesSimpleLink() {
        let links = NoteStore.parseWikiLinks(from: "See [[Hello World]] for more.")
        XCTAssertEqual(links, ["Hello World"])
    }

    func testParsesMultipleLinks() {
        let links = NoteStore.parseWikiLinks(from: "[[A]] and [[B]] are linked.")
        XCTAssertEqual(Set(links), Set(["A", "B"]))
    }

    func testTrimsWhitespaceFromLinks() {
        let links = NoteStore.parseWikiLinks(from: "[[ My Note ]]")
        XCTAssertEqual(links, ["My Note"])
    }

    func testIgnoresNestedBrackets() {
        let links = NoteStore.parseWikiLinks(from: "[[[broken]]]")
        // Outer brackets don't form a valid [[...]] pair — should be empty or skip
        XCTAssertTrue(links.isEmpty || links == ["broken"])
    }

    func testEmptyBodyReturnsEmpty() {
        XCTAssertEqual(NoteStore.parseWikiLinks(from: ""), [])
    }

    func testNoLinksInPlainText() {
        let links = NoteStore.parseWikiLinks(from: "Just plain text here.")
        XCTAssertTrue(links.isEmpty)
    }

    func testResolutionCaseInsensitive() throws {
        let db = try DatabaseManager(path: ":memory:")
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "Swift Tips", body: "", tags: [])
        let resolved = try store.resolveTitle("swift tips")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.title, "Swift Tips")
    }

    func testResolutionNilForUnknown() throws {
        let db = try DatabaseManager(path: ":memory:")
        let store = NoteStore(databaseManager: db)
        let resolved = try store.resolveTitle("nonexistent")
        XCTAssertNil(resolved)
    }
}
```

- [ ] **Step 2: Run parser tests**

```bash
swift test --filter WikiLinkParserTests 2>&1 | tail -15
```

Expected: 8 tests pass.

- [ ] **Step 3: Commit**

```bash
git add ScribeTests/WikiLinkParserTests.swift
git commit -m "test(notes): wiki-link parser + resolution tests"
```

---

## Task 4: Move MarkdownEditorView to DesignSystem + add extraHighlighter hook

**Files:**
- Move: `Scribe/UI/Tasks/MarkdownEditorView.swift` → `Scribe/UI/DesignSystem/MarkdownEditorView.swift`
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (add `extraHighlighter` param)

- [ ] **Step 1: Move the file**

```bash
mv Scribe/UI/Tasks/MarkdownEditorView.swift Scribe/UI/DesignSystem/MarkdownEditorView.swift
```

- [ ] **Step 2: Add `extraHighlighter` parameter to `MarkdownEditorView`**

Open `Scribe/UI/DesignSystem/MarkdownEditorView.swift`. Add a new stored property after `font`:

```swift
    var extraHighlighter: ((NSMutableAttributedString) -> Void)? = nil
```

Then in the Coordinator's `textDidChange` method (where syntax highlighting is applied), after the existing highlighting pass, add a call to the extra highlighter. Find the method that applies attributes to the attributed string — it will look something like:

```swift
    // In the Coordinator, after applying standard markdown attributes:
    if let extra = parent.extraHighlighter {
        let mutable = NSMutableAttributedString(attributedString: tv.attributedString())
        extra(mutable)
        // Only update if the extra highlighter made changes (avoid cursor jump)
        if mutable.string == tv.string {
            let selectedRange = tv.selectedRange()
            tv.textStorage?.setAttributedString(mutable)
            tv.setSelectedRange(selectedRange)
        }
    }
```

> **Note:** Find the exact location by searching for `textDidChange` or `NSTextViewDelegate` in the file. The extra highlighter call goes at the end of the existing highlighting method, after the standard markdown passes.

- [ ] **Step 3: Regenerate Xcode project**

```bash
xcodegen generate
```

- [ ] **Step 4: Build to verify Tasks still compiles**

```bash
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift
git rm Scribe/UI/Tasks/MarkdownEditorView.swift 2>/dev/null || true
git add -u
git commit -m "refactor(notes): move MarkdownEditorView to DesignSystem, add extraHighlighter hook"
```

---

## Task 5: NoteEditorView with wiki-link highlighting and autocomplete

**Files:**
- Create: `Scribe/UI/Notes/NoteEditorView.swift`

- [ ] **Step 1: Create `Scribe/UI/Notes/NoteEditorView.swift`**

```swift
// Scribe/UI/Notes/NoteEditorView.swift
import SwiftUI
import AppKit

/// Wraps the shared MarkdownEditorView and adds [[...]] highlighting +
/// an autocomplete popup triggered when the user types "[[".
struct NoteEditorView: View {

    @Binding var text: String
    var noteStore: NoteStore
    var onNavigate: (String) -> Void  // called with anchorText when user clicks a [[link]]

    @State private var wikiQuery: String? = nil      // nil = popup hidden
    @State private var suggestions: [Note] = []
    @State private var selectedSuggestion: Int = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkdownEditorView(
                text: $text,
                placeholder: "Write your note…",
                extraHighlighter: highlightWikiLinks(_:),
                onWikiLinkTyped: { query in
                    wikiQuery = query
                    Task { await loadSuggestions(query: query) }
                },
                onWikiLinkNavigate: { anchor in onNavigate(anchor) }
            )

            if let query = wikiQuery, !suggestions.isEmpty {
                WikiLinkPopup(
                    suggestions: suggestions,
                    selected: $selectedSuggestion,
                    onPick: { note in
                        insertCompletion(note: note)
                        wikiQuery = nil
                        suggestions = []
                    },
                    onDismiss: { wikiQuery = nil }
                )
                .padding(.top, 8)
                .padding(.leading, 4)
                .zIndex(1)
            }
        }
        .onChange(of: wikiQuery) { _, q in
            if q == nil { suggestions = []; selectedSuggestion = 0 }
        }
    }

    private func highlightWikiLinks(_ attrStr: NSMutableAttributedString) {
        let pattern = #"\[\[([^\[\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let full = NSRange(attrStr.string.startIndex..., in: attrStr.string)
        regex.enumerateMatches(in: attrStr.string, range: full) { match, _, _ in
            guard let match else { return }
            attrStr.addAttribute(.foregroundColor,
                                 value: NSColor.systemBlue,
                                 range: match.range)
            attrStr.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: match.range)
        }
    }

    @MainActor
    private func loadSuggestions(query: String) async {
        guard !query.isEmpty else {
            suggestions = (try? noteStore.fetchAllNotes()) ?? []
            return
        }
        suggestions = (try? noteStore.searchNotes(query: query)) ?? []
        selectedSuggestion = 0
    }

    private func insertCompletion(note: Note) {
        // Find the last "[[" in text and replace everything after it with "[[Title]]"
        guard let range = text.range(of: "[[", options: .backwards) else { return }
        text = String(text[..<range.lowerBound]) + "[[\(note.title)]]"
    }
}

// MARK: - WikiLinkPopup

private struct WikiLinkPopup: View {
    let suggestions: [Note]
    @Binding var selected: Int
    let onPick: (Note) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.offset) { idx, note in
                Button {
                    onPick(note)
                } label: {
                    Text(note.title.isEmpty ? "(Untitled)" : note.title)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(idx == selected
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onExitCommand { onDismiss() }
    }
}
```

> **Note:** The `onWikiLinkTyped` and `onWikiLinkNavigate` closures need to be added to `MarkdownEditorView`. Add them in Step 2.

- [ ] **Step 2: Add `onWikiLinkTyped` and `onWikiLinkNavigate` to `MarkdownEditorView`**

In `Scribe/UI/DesignSystem/MarkdownEditorView.swift`, add two new optional closure properties:

```swift
    var onWikiLinkTyped: ((String) -> Void)? = nil   // called with text after "[[" while typing
    var onWikiLinkNavigate: ((String) -> Void)? = nil // called when user clicks a [[link]]
```

In the Coordinator's `textDidChange`, detect the `[[` trigger:

```swift
    // After existing highlight calls, detect live [[query
    private func detectWikiLinkTyping(in tv: NSTextView) {
        let text = tv.string
        let cursorPos = tv.selectedRange().location
        guard cursorPos >= 2 else {
            parent.onWikiLinkTyped?(nil as String? ?? "")
            return
        }
        let upToCursor = String(text.prefix(cursorPos))
        if let bracketRange = upToCursor.range(of: "[[", options: .backwards),
           !upToCursor[bracketRange.upperBound...].contains("]]") {
            let query = String(upToCursor[bracketRange.upperBound...])
            parent.onWikiLinkTyped?(query)
        } else {
            parent.onWikiLinkTyped?("")
        }
    }
```

Call `detectWikiLinkTyping(in: tv)` at the end of `textDidChange`.

For click navigation, override `mouseDown` in `MarkdownNSTextView` or implement `textView(_:clickedOnLink:at:)` in the delegate. Since `[[links]]` are plain styled text (not actual NSURL links), use a simpler approach: detect clicks on blue-underlined runs:

```swift
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString text: String?) -> Bool {
        // Navigation click is handled via the custom click gesture below
        return true
    }
```

Add to the Coordinator:

```swift
    @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let tv = recognizer.view as? NSTextView else { return }
        let point = recognizer.location(in: tv)
        let glyphIdx = tv.layoutManager?.glyphIndex(for: point,
            in: tv.textContainer ?? NSTextContainer()) ?? NSNotFound
        guard glyphIdx != NSNotFound else { return }
        let charIdx = tv.layoutManager?.characterIndexForGlyph(at: glyphIdx) ?? NSNotFound
        guard charIdx != NSNotFound, charIdx < tv.string.utf16.count else { return }
        let nsRange = NSRange(location: charIdx, length: 0)
        tv.textStorage?.enumerateAttributes(in: nsRange, options: .longestEffectiveRangeNotRequired) { attrs, _, _ in
            if attrs[.foregroundColor] as? NSColor == NSColor.systemBlue {
                // find the wiki-link text around this position
                let full = tv.string as NSString
                var start = charIdx
                var end = charIdx
                while start > 0, full.character(at: start - 1) != "[".utf16.first { start -= 1 }
                while end < full.length, full.character(at: end) != "]".utf16.first { end += 1 }
                if start >= 2, end < full.length - 1 {
                    let anchor = full.substring(with: NSRange(location: start, length: end - start))
                    parent.onWikiLinkNavigate?(anchor)
                }
            }
        }
    }
```

Register this gesture recognizer in `makeNSView`:

```swift
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        tv.addGestureRecognizer(click)
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/Notes/NoteEditorView.swift Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "feat(notes): NoteEditorView with [[...]] highlighting + autocomplete popup"
```

---

## Task 6: NoteListView + NoteListViewModel

**Files:**
- Create: `Scribe/UI/Notes/NoteListViewModel.swift`
- Create: `Scribe/UI/Notes/NoteListView.swift`

- [ ] **Step 1: Create `NoteListViewModel.swift`**

```swift
// Scribe/UI/Notes/NoteListViewModel.swift
import Foundation
import Combine

@MainActor
final class NoteListViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var searchText: String = ""
    @Published var errorMessage: String? = nil

    private let store: NoteStore
    private var cancellables = Set<AnyCancellable>()

    init(store: NoteStore = .shared) {
        self.store = store
        store.observeNotes()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] notes in self?.notes = notes })
            .store(in: &cancellables)
    }

    var filteredNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        let lower = q.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(lower) || $0.body.lowercased().contains(lower)
        }
    }

    func createNote() -> Note? {
        try? store.createNote(title: "", body: "", tags: [])
    }

    func deleteNote(id: String) {
        do { try store.deleteNote(id: id) }
        catch { errorMessage = error.localizedDescription }
    }
}
```

- [ ] **Step 2: Create `NoteListView.swift`**

```swift
// Scribe/UI/Notes/NoteListView.swift
import SwiftUI

struct NoteListView: View {
    @StateObject private var vm = NoteListViewModel()
    @Binding var selectedNoteId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes…", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.background.secondary)

            Divider()

            if vm.filteredNotes.isEmpty {
                ContentUnavailableView(
                    "No notes",
                    systemImage: "note.text",
                    description: Text("Press ⌘N to create your first note.")
                )
            } else {
                List(vm.filteredNotes, selection: $selectedNoteId) { note in
                    NoteRowView(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.deleteNote(id: note.id)
                                if selectedNoteId == note.id { selectedNoteId = nil }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.sidebar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let note = vm.createNote()
                    selectedNoteId = note?.id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

private struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "(Untitled)" : note.title)
                .font(.body)
                .lineLimit(1)
            Text(note.body.isEmpty ? "No additional text" : note.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/Notes/NoteListViewModel.swift Scribe/UI/Notes/NoteListView.swift
git commit -m "feat(notes): NoteListView + NoteListViewModel"
```

---

## Task 7: NoteDetailView + NoteBacklinksView

**Files:**
- Create: `Scribe/UI/Notes/NoteDetailViewModel.swift`
- Create: `Scribe/UI/Notes/NoteBacklinksView.swift`
- Create: `Scribe/UI/Notes/NoteDetailView.swift`

- [ ] **Step 1: Create `NoteDetailViewModel.swift`**

```swift
// Scribe/UI/Notes/NoteDetailViewModel.swift
import Foundation
import Combine

@MainActor
final class NoteDetailViewModel: ObservableObject {
    @Published var note: Note
    @Published var tags: [String] = []
    @Published var backlinks: [Note] = []
    @Published var isDirty: Bool = false
    @Published var errorMessage: String? = nil

    private let store: NoteStore
    var onNavigate: ((String) -> Void)?  // called with noteId to navigate

    init(note: Note, store: NoteStore = .shared) {
        self.note = note
        self.store = store
        load()
    }

    private func load() {
        do {
            tags = try store.tags(for: note.id)
            backlinks = try store.backlinks(for: note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() {
        do {
            try store.updateNote(note, tags: tags)
            backlinks = (try? store.backlinks(for: note.id)) ?? []
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleWikiLinkNavigate(anchor: String) {
        guard let target = try? store.resolveTitle(anchor) else { return }
        onNavigate?(target.id)
    }

    func markDirty() { isDirty = true }
}
```

- [ ] **Step 2: Create `NoteBacklinksView.swift`**

```swift
// Scribe/UI/Notes/NoteBacklinksView.swift
import SwiftUI

struct NoteBacklinksView: View {
    let backlinks: [Note]
    let onNavigate: (String) -> Void  // noteId

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Linked from")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider()

            if backlinks.isEmpty {
                Text("No notes link here yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(backlinks) { note in
                            Button {
                                onNavigate(note.id)
                            } label: {
                                Text(note.title.isEmpty ? "(Untitled)" : note.title)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 220)
        .background(.background.secondary)
    }
}
```

- [ ] **Step 3: Create `NoteDetailView.swift`**

```swift
// Scribe/UI/Notes/NoteDetailView.swift
import SwiftUI

struct NoteDetailView: View {
    @StateObject private var vm: NoteDetailViewModel
    var onNavigate: (String) -> Void  // noteId

    init(note: Note, onNavigate: @escaping (String) -> Void) {
        _vm = StateObject(wrappedValue: NoteDetailViewModel(note: note))
        self.onNavigate = onNavigate
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Title", text: titleBinding)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider()

                NoteEditorView(
                    text: bodyBinding,
                    noteStore: .shared,
                    onNavigate: { anchor in vm.handleWikiLinkNavigate(anchor: anchor) }
                )
                .padding(8)
            }

            Divider()

            NoteBacklinksView(backlinks: vm.backlinks, onNavigate: onNavigate)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { vm.save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!vm.isDirty)
            }
        }
        .onChange(of: vm.note.title) { _, _ in vm.markDirty() }
        .onChange(of: vm.note.body) { _, _ in vm.markDirty() }
        .onReceive(NotificationCenter.default.publisher(for: .saveCurrentNote)) { _ in
            if vm.isDirty { vm.save() }
        }
        .onAppear { vm.onNavigate = onNavigate }
        .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil },
                                             set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private var titleBinding: Binding<String> {
        Binding(get: { vm.note.title }, set: { vm.note.title = $0 })
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { vm.note.body }, set: { vm.note.body = $0 })
    }
}
```

Add the notification name. In `MainWindowView.swift`, in the `extension Notification.Name` block, add:

```swift
    static let saveCurrentNote = Notification.Name("saveCurrentNote")
```

- [ ] **Step 4: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/Notes/NoteDetailViewModel.swift Scribe/UI/Notes/NoteBacklinksView.swift Scribe/UI/Notes/NoteDetailView.swift Scribe/UI/MainWindow/MainWindowView.swift
git commit -m "feat(notes): NoteDetailView split editor+backlinks, NoteDetailViewModel"
```

---

## Task 8: Wire Notes into MainWindowView sidebar

**Files:**
- Modify: `Scribe/UI/MainWindow/MainWindowView.swift`

- [ ] **Step 1: Add `NotesFilter` enum and extend `MainSelection`**

At the top of `MainWindowView.swift`, after the `MainSelection` enum, add:

```swift
enum NotesFilter: Hashable {
    case all
    case today
    case daily
    case tag(String)
    case graph
}
```

Extend `MainSelection`:

```swift
enum MainSelection: Hashable {
    case live
    case transcript(String)
    case tasks(TaskStore.Filter)
    case taskCalendar
    case note(String)           // noteId
    case notes(NotesFilter)
    case settings(SettingsPane)
}
```

- [ ] **Step 2: Add `notesExpanded` state and Notes sidebar section**

Add state:
```swift
    @State private var notesExpanded: Bool = true
```

Inside the sidebar `List`, after the Projects section and before the Transcripts section, add:

```swift
            Section {
                if notesExpanded {
                    NavigationLink(value: MainSelection.notes(.today)) {
                        Label("Today", systemImage: "sun.max")
                    }
                    NavigationLink(value: MainSelection.notes(.all)) {
                        Label("All Notes", systemImage: "note.text")
                    }
                    NavigationLink(value: MainSelection.notes(.daily)) {
                        Label("Daily Notes", systemImage: "calendar.badge.clock")
                    }
                    NavigationLink(value: MainSelection.notes(.graph)) {
                        Label("Graph", systemImage: "circle.hexagongrid")
                    }
                }
            } header: {
                CollapsibleSectionHeader(title: "Notes", isExpanded: $notesExpanded)
            }
```

- [ ] **Step 3: Add note cases to the detail switch**

In the `detail` computed property, add before `case .none`:

```swift
        case .note(let id):
            if let note = try? NoteStore.shared.fetchNote(id: id) {
                NoteDetailView(note: note, onNavigate: { noteId in
                    selection = .note(noteId)
                })
                .id(id)
            } else {
                EmptyStateView(systemImage: "note.text",
                               title: "Note not found",
                               message: "This note may have been deleted.")
            }
        case .notes(let filter):
            NoteListView(selectedNoteId: Binding(
                get: { if case .note(let id) = selection { return id } else { return nil } },
                set: { id in selection = id.map { .note($0) } ?? .notes(filter) }
            ))
        case .notes(.graph):
            GraphView(onNavigate: { id in selection = .note(id) })
```

> **Note:** The `.notes(.graph)` case must come before the general `.notes(let filter)` case in the switch. In Swift, pattern matching is ordered, but since both patterns match `.notes(...)`, add the graph case first or use a where clause on the general case.

Replace the above with a single cleaner switch:

```swift
        case .notes(let filter):
            switch filter {
            case .graph:
                GraphView(onNavigate: { id in selection = .note(id) })
            case .today:
                if let note = try? NoteStore.shared.dailyNote(for: Date()) {
                    NoteDetailView(note: note, onNavigate: { selection = .note($0) })
                        .id(note.id)
                }
            default:
                NoteListView(selectedNoteId: Binding(
                    get: { if case .note(let id) = selection { return id } else { return nil } },
                    set: { id in selection = id.map { .note($0) } ?? .notes(filter) }
                ))
            }
```

- [ ] **Step 4: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/MainWindow/MainWindowView.swift
git commit -m "feat(notes): Notes sidebar section, NotesFilter, MainSelection extended"
```

---

## Task 9: Daily notes + NoteCalendarView

**Files:**
- Create: `Scribe/UI/Notes/DailyNoteView.swift`
- Create: `Scribe/UI/Notes/NoteCalendarView.swift`
- Create: `ScribeTests/DailyNoteTests.swift`

- [ ] **Step 1: Write daily note tests**

```swift
// ScribeTests/DailyNoteTests.swift
import XCTest
@testable import Scribe

final class DailyNoteTests: XCTestCase {
    private var db: DatabaseManager!
    private var store: NoteStore!

    override func setUp() throws {
        db = try DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: db)
    }

    func testDailyNoteTitleFormat() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 7))!
        let note = try store.dailyNote(for: date)
        XCTAssertTrue(note.title.contains("May 7, 2026"))
        XCTAssertTrue(note.title.hasPrefix("Daily Note –"))
    }

    func testDailyNoteIsIdempotent() throws {
        let date = Date()
        let a = try store.dailyNote(for: date)
        let b = try store.dailyNote(for: date)
        XCTAssertEqual(a.id, b.id)
    }

    func testDifferentDatesGetDifferentNotes() throws {
        let cal = Calendar.current
        let today = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let a = try store.dailyNote(for: today)
        let b = try store.dailyNote(for: yesterday)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.dailyDate, b.dailyDate)
    }

    func testDailyNoteHasDailyFlag() throws {
        let note = try store.dailyNote(for: Date())
        XCTAssertTrue(note.isDailyNote)
        XCTAssertNotNil(note.dailyDate)
    }

    func testDailyNoteDateKeyFormat() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let note = try store.dailyNote(for: date)
        XCTAssertEqual(note.dailyDate, "2026-01-05")
    }
}
```

- [ ] **Step 2: Run daily note tests**

```bash
swift test --filter DailyNoteTests 2>&1 | tail -15
```

Expected: 5 tests pass.

- [ ] **Step 3: Create `NoteCalendarView.swift`**

```swift
// Scribe/UI/Notes/NoteCalendarView.swift
import SwiftUI

struct NoteCalendarView: View {
    @State private var displayedMonth: Date = {
        Calendar.current.startOfMonth(for: Date())
    }()
    @State private var datesWithNotes: Set<String> = []
    var onSelectDate: (Date) -> Void

    private let store = NoteStore.shared
    private let calendar = Calendar.current
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(spacing: 8) {
            // Month navigation
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(displayedMonth, format: .dateTime.month().year())
                    .font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)

            // Day-of-week header
            let weekdays = ["Su","Mo","Tu","We","Th","Fr","Sa"]
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day grid
            let days = monthDays()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                      spacing: 0) {
                ForEach(days.indices, id: \.self) { idx in
                    if let date = days[idx] {
                        let key = Self.keyFormatter.string(from: date)
                        let hasNote = datesWithNotes.contains(key)
                        let isToday = calendar.isDateInToday(date)
                        Button {
                            onSelectDate(date)
                        } label: {
                            ZStack {
                                if isToday {
                                    Circle().fill(Color.accentColor).frame(width: 26, height: 26)
                                }
                                VStack(spacing: 1) {
                                    Text("\(calendar.component(.day, from: date))")
                                        .font(.callout)
                                        .foregroundStyle(isToday ? .white : .primary)
                                    if hasNote {
                                        Circle()
                                            .fill(isToday ? Color.white : Color.accentColor)
                                            .frame(width: 4, height: 4)
                                    }
                                }
                            }
                            .frame(height: 36)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
            }
        }
        .padding(8)
        .onAppear { loadDailyNoteDates() }
        .onChange(of: displayedMonth) { _, _ in loadDailyNoteDates() }
    }

    private func shiftMonth(_ delta: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
    }

    private func monthDays() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let firstDay = monthInterval.start
        let weekday = calendar.component(.weekday, from: firstDay) - 1  // 0-indexed, Sunday=0
        var days: [Date?] = Array(repeating: nil, count: weekday)
        var current = firstDay
        while current < monthInterval.end {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return days
    }

    private func loadDailyNoteDates() {
        let notes = (try? NoteStore.shared.fetchAllNotes()) ?? []
        datesWithNotes = Set(notes.compactMap(\.dailyDate))
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? date
    }
}
```

- [ ] **Step 4: Create `DailyNoteView.swift`**

```swift
// Scribe/UI/Notes/DailyNoteView.swift
import SwiftUI

/// Shows the NoteCalendarView plus a detail pane for the selected daily note.
struct DailyNoteView: View {
    @State private var selectedNote: Note? = nil
    var onNavigate: (String) -> Void  // noteId

    var body: some View {
        HSplitView {
            NoteCalendarView { date in
                selectedNote = try? NoteStore.shared.dailyNote(for: date)
            }
            .frame(minWidth: 240, maxWidth: 280)

            if let note = selectedNote {
                NoteDetailView(note: note, onNavigate: onNavigate)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "Select a day",
                    systemImage: "calendar",
                    description: Text("Pick a date to view or create that day's note.")
                )
            }
        }
        .onAppear {
            selectedNote = try? NoteStore.shared.dailyNote(for: Date())
        }
    }
}
```

- [ ] **Step 5: Wire `.notes(.daily)` in MainWindowView detail switch**

In the `case .notes(let filter)` switch in `MainWindowView.swift`, update the `daily` case:

```swift
            case .daily:
                DailyNoteView(onNavigate: { selection = .note($0) })
```

- [ ] **Step 6: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 7: Commit**

```bash
git add Scribe/UI/Notes/NoteCalendarView.swift Scribe/UI/Notes/DailyNoteView.swift ScribeTests/DailyNoteTests.swift Scribe/UI/MainWindow/MainWindowView.swift
git commit -m "feat(notes): daily notes, NoteCalendarView, DailyNoteView (slice 12 part 1)"
```

---

## Task 10: Unified tags pane

**Files:**
- Modify: `Scribe/UI/MainWindow/MainWindowView.swift`

- [ ] **Step 1: Add `notesTagsExpanded` state and unified tag sidebar section**

Add state:
```swift
    @State private var notesTagsExpanded: Bool = false
```

After the Notes section in the sidebar, add:

```swift
            Section {
                if notesTagsExpanded {
                    ForEach(unifiedTags, id: \.self) { tag in
                        NavigationLink(value: MainSelection.notes(.tag(tag))) {
                            Label(tag, systemImage: "tag")
                        }
                    }
                }
            } header: {
                CollapsibleSectionHeader(title: "Tags", isExpanded: $notesTagsExpanded)
            }
```

- [ ] **Step 2: Compute unified tag list in `MainWindowView`**

Add a computed property (or `@State` populated on appear):

```swift
    @State private var unifiedTags: [String] = []

    private func reloadTags() {
        let noteTags = (try? NoteStore.shared.allNoteTags()) ?? []
        let taskTags = (try? taskStore.allTags()) ?? []  // see step 3
        unifiedTags = Array(Set(noteTags + taskTags)).sorted()
    }
```

Call `reloadTags()` in `.onAppear` and subscribe to a notification fired by NoteStore/TaskStore on tag changes (or simply reload whenever the notes section is expanded).

Add `.onAppear { reloadTags() }` to the sidebar `List`.

- [ ] **Step 3: Add `allTags()` to `TaskStore`**

In `Scribe/Storage/TaskStore.swift`, add:

```swift
    func allTags() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database, sql: "SELECT DISTINCT tag FROM task_tags ORDER BY tag")
        }
    }
```

Also add `@StateObject private var taskStore = TaskStore()` (or use the existing one if already available) in `MainWindowView`.

> **Note:** `MainWindowView` already has `projectsViewModel` which uses `TaskStore` indirectly. Add `@StateObject private var taskStoreRef = TaskStore()` if `TaskStore` isn't already accessible, or access `TaskStore.shared` if you add a `shared` singleton (same pattern as `NoteStore.shared`).

Add to `TaskStore`:
```swift
    static let shared = TaskStore(databaseManager: .shared)
```

- [ ] **Step 4: Handle `.notes(.tag(String))` in detail**

In the `case .notes(let filter)` switch, add:

```swift
            case .tag(let tag):
                TaggedContentView(tag: tag, onNavigate: { selection = .note($0) })
```

Create `Scribe/UI/Notes/TaggedContentView.swift`:

```swift
// Scribe/UI/Notes/TaggedContentView.swift
import SwiftUI

/// Shows notes and tasks that share a given tag.
struct TaggedContentView: View {
    let tag: String
    var onNavigate: (String) -> Void

    @State private var notes: [Note] = []
    @State private var tasks: [TodoTask] = []

    var body: some View {
        List {
            if !notes.isEmpty {
                Section("Notes") {
                    ForEach(notes) { note in
                        Button(note.title.isEmpty ? "(Untitled)" : note.title) {
                            onNavigate(note.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !tasks.isEmpty {
                Section("Tasks") {
                    ForEach(tasks) { task in
                        Text(task.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if notes.isEmpty && tasks.isEmpty {
                ContentUnavailableView("No items tagged #\(tag)",
                                       systemImage: "tag")
            }
        }
        .navigationTitle("#\(tag)")
        .onAppear { load() }
    }

    private func load() {
        notes = (try? NoteStore.shared.fetchAllNotes()
            .filter { (try? NoteStore.shared.tags(for: $0.id))?.contains(tag) ?? false }) ?? []
        tasks = (try? TaskStore.shared.fetchTasks(filter: .tag(tag))) ?? []
    }
}
```

- [ ] **Step 5: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 6: Commit**

```bash
git add Scribe/UI/MainWindow/MainWindowView.swift Scribe/Storage/TaskStore.swift Scribe/UI/Notes/TaggedContentView.swift
git commit -m "feat(notes): unified tag pane across notes + tasks (slice 12 part 2)"
```

---

## Task 11: Universal search

**Files:**
- Create: `Scribe/UI/Notes/UniversalSearchViewModel.swift`
- Create: `Scribe/UI/Notes/UniversalSearchView.swift`
- Create: `ScribeTests/UniversalSearchTests.swift`
- Modify: `Scribe/UI/MainWindow/MainWindowView.swift`

- [ ] **Step 1: Write universal search tests**

```swift
// ScribeTests/UniversalSearchTests.swift
import XCTest
@testable import Scribe

final class UniversalSearchTests: XCTestCase {
    private var db: DatabaseManager!
    private var noteStore: NoteStore!
    private var taskStore: TaskStore!

    override func setUp() throws {
        db = try DatabaseManager(path: ":memory:")
        noteStore = NoteStore(databaseManager: db)
        taskStore = TaskStore(databaseManager: db)
    }

    func testSearchNotesReturnsMatches() throws {
        _ = try noteStore.createNote(title: "Alpha", body: "unique keyword here", tags: [])
        _ = try noteStore.createNote(title: "Beta", body: "different content", tags: [])
        let results = try noteStore.searchNotes(query: "unique")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Alpha")
    }

    func testSearchNotesEmptyQueryReturnsAll() throws {
        _ = try noteStore.createNote(title: "A", body: "", tags: [])
        _ = try noteStore.createNote(title: "B", body: "", tags: [])
        let results = try noteStore.searchNotes(query: "")
        XCTAssertEqual(results.count, 2)
    }

    func testSearchTasksReturnsMatches() throws {
        _ = try taskStore.createTask(title: "Buy groceries", notes: "milk eggs bread")
        _ = try taskStore.createTask(title: "Write report", notes: "quarterly analysis")
        let results = try taskStore.searchTasks(query: "groceries")
        XCTAssertEqual(results.count, 1)
    }
}
```

- [ ] **Step 2: Add `createTask` helper if missing from TaskStore**

Check if `TaskStore` has a `createTask(title:notes:)` convenience. If not, use:

```swift
// In UniversalSearchTests.setUp or the test itself:
var t = TodoTask(title: "Buy groceries", notes: "milk eggs bread")
try taskStore.saveTask(t, tags: [])
```

> Adjust based on the actual TaskStore API. Look at `TaskStoreTests.swift` for the correct call pattern.

- [ ] **Step 3: Run search tests**

```bash
swift test --filter UniversalSearchTests 2>&1 | tail -15
```

Expected: 3 tests pass.

- [ ] **Step 4: Create `UniversalSearchViewModel.swift`**

```swift
// Scribe/UI/Notes/UniversalSearchViewModel.swift
import Foundation
import Combine

struct SearchResult: Identifiable {
    let id: String
    let title: String
    let snippet: String
    let destination: MainSelection
    let icon: String
}

struct SearchResultSection: Identifiable {
    let id: String
    let title: String
    let results: [SearchResult]
}

@MainActor
final class UniversalSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var sections: [SearchResultSection] = []

    private var debounce: Task<Void, Never>?
    private let noteStore: NoteStore
    private let taskStore: TaskStore

    init(noteStore: NoteStore = .shared, taskStore: TaskStore = .shared) {
        self.noteStore = noteStore
        self.taskStore = taskStore
    }

    func scheduleSearch() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    private func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)

        async let noteResults = searchNotes(q)
        async let taskResults = searchTasks(q)
        async let transcriptResults = searchTranscripts(q)

        let (notes, tasks, transcripts) = await (noteResults, taskResults, transcriptResults)

        sections = [notes, tasks, transcripts].filter { !$0.results.isEmpty }
    }

    private func searchNotes(_ q: String) async -> SearchResultSection {
        let notes = (try? noteStore.searchNotes(query: q)) ?? []
        let results = notes.prefix(10).map { note in
            SearchResult(
                id: "note-\(note.id)",
                title: note.title.isEmpty ? "(Untitled)" : note.title,
                snippet: String(note.body.prefix(80)),
                destination: .note(note.id),
                icon: "note.text"
            )
        }
        return SearchResultSection(id: "notes", title: "Notes", results: Array(results))
    }

    private func searchTasks(_ q: String) async -> SearchResultSection {
        let tasks = (try? taskStore.searchTasks(query: q)) ?? []
        let results = tasks.prefix(10).map { task in
            SearchResult(
                id: "task-\(task.id)",
                title: task.title,
                snippet: String(task.notes.prefix(80)),
                destination: .tasks(.all),
                icon: "checkmark.circle"
            )
        }
        return SearchResultSection(id: "tasks", title: "Tasks", results: Array(results))
    }

    private func searchTranscripts(_ q: String) async -> SearchResultSection {
        guard !q.isEmpty else {
            return SearchResultSection(id: "transcripts", title: "Transcripts", results: [])
        }
        let matches = (try? TranscriptStore(databaseManager: .shared).searchTranscripts(query: q)) ?? []
        let results = matches.prefix(5).map { (session, _) in
            SearchResult(
                id: "session-\(session.id)",
                title: session.title,
                snippet: session.language ?? "",
                destination: .transcript(session.id),
                icon: "waveform"
            )
        }
        return SearchResultSection(id: "transcripts", title: "Transcripts", results: Array(results))
    }
}
```

> **Note:** `TranscriptStore` is initialized with `databaseManager:` — verify this matches its actual initializer. If `TranscriptStore` doesn't expose an `init(databaseManager:)`, use `TranscriptStore(database: DatabaseManager.shared.database)` or however it's constructed.

- [ ] **Step 5: Create `UniversalSearchView.swift`**

```swift
// Scribe/UI/Notes/UniversalSearchView.swift
import SwiftUI

struct UniversalSearchView: View {
    @StateObject private var vm = UniversalSearchViewModel()
    @Binding var isPresented: Bool
    var onNavigate: (MainSelection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes, tasks, transcripts…", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { selectFirst() }
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Divider()

            if vm.sections.isEmpty {
                Text(vm.query.isEmpty ? "Start typing to search…" : "No results")
                    .foregroundStyle(.secondary)
                    .padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(vm.sections) { section in
                            Section {
                                ForEach(section.results) { result in
                                    Button {
                                        isPresented = false
                                        onNavigate(result.destination)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: result.icon)
                                                .frame(width: 20)
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(result.title)
                                                    .font(.body)
                                                if !result.snippet.isEmpty {
                                                    Text(result.snippet)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .hoverEffect()

                                    Divider().padding(.leading, 46)
                                }
                            } header: {
                                Text(section.title)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onChange(of: vm.query) { _, _ in vm.scheduleSearch() }
        .onExitCommand { isPresented = false }
    }

    private func selectFirst() {
        guard let first = vm.sections.first?.results.first else { return }
        isPresented = false
        onNavigate(first.destination)
    }
}
```

- [ ] **Step 6: Add universal search trigger to MainWindowView**

Add state:
```swift
    @State private var showUniversalSearch: Bool = false
```

Add overlay to the main `NavigationSplitView`:
```swift
        .overlay(alignment: .top) {
            if showUniversalSearch {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showUniversalSearch = false }
                    .overlay(alignment: .top) {
                        UniversalSearchView(isPresented: $showUniversalSearch) { dest in
                            selection = dest
                        }
                        .padding(.top, 60)
                    }
            }
        }
```

Register `Cmd-Shift-F` shortcut. In the `.onAppear` block or toolbar, add:

```swift
        .keyboardShortcut("f", modifiers: [.command, .shift])
```

Or add a hidden button in the toolbar:

```swift
        .background(
            Button("") { showUniversalSearch.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        )
```

- [ ] **Step 7: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 8: Commit**

```bash
git add Scribe/UI/Notes/UniversalSearchViewModel.swift Scribe/UI/Notes/UniversalSearchView.swift ScribeTests/UniversalSearchTests.swift Scribe/UI/MainWindow/MainWindowView.swift
git commit -m "feat(notes): universal search Cmd-Shift-F (slice 13)"
```

---

## Task 12: GraphViewModel

**Files:**
- Create: `Scribe/UI/Notes/GraphViewModel.swift`
- Create: `ScribeTests/GraphViewModelTests.swift`

- [ ] **Step 1: Write GraphViewModel tests**

```swift
// ScribeTests/GraphViewModelTests.swift
import XCTest
@testable import Scribe

final class GraphViewModelTests: XCTestCase {
    private var db: DatabaseManager!
    private var noteStore: NoteStore!

    override func setUp() throws {
        db = try DatabaseManager(path: ":memory:")
        noteStore = NoteStore(databaseManager: db)
    }

    func testNodesCreatedForNotes() throws {
        _ = try noteStore.createNote(title: "A", body: "", tags: [])
        _ = try noteStore.createNote(title: "B", body: "", tags: [])
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertEqual(vm.nodes.filter { $0.type == .note }.count, 2)
    }

    func testEdgesCreatedForWikiLinks() throws {
        let a = try noteStore.createNote(title: "Alpha", body: "[[Beta]]", tags: [])
        let b = try noteStore.createNote(title: "Beta", body: "", tags: [])
        try noteStore.updateNote(a, tags: [])  // triggers link parse
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertEqual(vm.edges.count, 1)
        let edge = vm.edges[0]
        XCTAssertEqual(edge.sourceId, a.id)
        XCTAssertEqual(edge.targetId, b.id)
    }

    func testIsSettledFalseInitially() throws {
        _ = try noteStore.createNote(title: "X", body: "", tags: [])
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertFalse(vm.isSettled)
    }

    func testEmptyGraphIsSettledImmediately() throws {
        let vm = GraphViewModel(noteStore: noteStore)
        try vm.load()
        XCTAssertTrue(vm.isSettled)
    }
}
```

- [ ] **Step 2: Create `GraphViewModel.swift`**

```swift
// Scribe/UI/Notes/GraphViewModel.swift
import Foundation
import CoreGraphics

struct GraphNode: Identifiable {
    let id: String
    let label: String
    let type: NodeType
    var position: CGPoint
    var velocity: CGPoint = .zero

    enum NodeType: Equatable {
        case note, session, task
        var color: (r: Double, g: Double, b: Double) {
            switch self {
            case .note:    return (0.2, 0.5, 1.0)
            case .session: return (0.2, 0.8, 0.4)
            case .task:    return (1.0, 0.6, 0.2)
            }
        }
    }
}

struct GraphEdge {
    let sourceId: String
    let targetId: String
}

@MainActor
final class GraphViewModel: ObservableObject {
    @Published private(set) var nodes: [GraphNode] = []
    @Published private(set) var edges: [GraphEdge] = []
    @Published private(set) var isSettled: Bool = true

    private let noteStore: NoteStore

    init(noteStore: NoteStore = .shared) {
        self.noteStore = noteStore
    }

    func load() throws {
        let notes = try noteStore.fetchAllNotes()
        guard !notes.isEmpty else {
            nodes = []; edges = []; isSettled = true; return
        }

        // Build nodes with random initial positions in a 600×600 area
        nodes = notes.map { note in
            GraphNode(
                id: note.id,
                label: note.title.isEmpty ? "(Untitled)" : String(note.title.prefix(20)),
                type: .note,
                position: CGPoint(
                    x: Double.random(in: 50...550),
                    y: Double.random(in: 50...550)
                )
            )
        }

        // Build edges from note_links
        let allNotes = try noteStore.fetchAllNotes()
        var edgeSet: [GraphEdge] = []
        for note in allNotes {
            let backlinks = try noteStore.backlinks(for: note.id)
            for source in backlinks {
                edgeSet.append(GraphEdge(sourceId: source.id, targetId: note.id))
            }
        }
        edges = edgeSet
        isSettled = false
    }

    // Call this from TimelineView's onChange(of:) — one tick per frame.
    func tick() {
        guard !isSettled else { return }
        guard nodes.count > 1 else { isSettled = true; return }

        let repulsionK: Double = 2000
        let springK: Double = 0.04
        let restLength: Double = 120
        let damping: Double = 0.85

        // Compute forces
        var forces = Array(repeating: CGPoint.zero, count: nodes.count)
        let nodeIds = nodes.map(\.id)

        // Repulsion between all pairs
        for i in nodes.indices {
            for j in nodes.indices where j != i {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let distSq = max(dx * dx + dy * dy, 1)
                let dist = distSq.squareRoot()
                let force = repulsionK / distSq
                forces[i].x += force * dx / dist
                forces[i].y += force * dy / dist
            }
        }

        // Spring attraction along edges
        for edge in edges {
            guard let si = nodeIds.firstIndex(of: edge.sourceId),
                  let ti = nodeIds.firstIndex(of: edge.targetId) else { continue }
            let dx = nodes[ti].position.x - nodes[si].position.x
            let dy = nodes[ti].position.y - nodes[si].position.y
            let dist = max((dx * dx + dy * dy).squareRoot(), 1)
            let stretch = dist - restLength
            let force = springK * stretch
            forces[si].x += force * dx / dist
            forces[si].y += force * dy / dist
            forces[ti].x -= force * dx / dist
            forces[ti].y -= force * dy / dist
        }

        // Integrate + damp
        var maxSpeed: Double = 0
        for i in nodes.indices {
            nodes[i].velocity.x = (nodes[i].velocity.x + forces[i].x) * damping
            nodes[i].velocity.y = (nodes[i].velocity.y + forces[i].y) * damping
            nodes[i].position.x += nodes[i].velocity.x
            nodes[i].position.y += nodes[i].velocity.y
            let speed = (nodes[i].velocity.x * nodes[i].velocity.x
                       + nodes[i].velocity.y * nodes[i].velocity.y).squareRoot()
            maxSpeed = max(maxSpeed, speed)
        }

        if maxSpeed < 0.5 { isSettled = true }
    }
}
```

- [ ] **Step 3: Run GraphViewModel tests**

```bash
swift test --filter GraphViewModelTests 2>&1 | tail -15
```

Expected: 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/Notes/GraphViewModel.swift ScribeTests/GraphViewModelTests.swift
git commit -m "feat(notes): GraphViewModel with Euler physics (slice 14 part 1)"
```

---

## Task 13: GraphView Canvas UI

**Files:**
- Create: `Scribe/UI/Notes/GraphView.swift`
- Modify: `Scribe/UI/MainWindow/MainWindowView.swift` (already wired in Task 8)

- [ ] **Step 1: Create `GraphView.swift`**

```swift
// Scribe/UI/Notes/GraphView.swift
import SwiftUI

struct GraphView: View {
    @StateObject private var vm = GraphViewModel()
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var dragStart: CGSize = .zero
    var onNavigate: (String) -> Void  // noteId

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: vm.isSettled)) { timeline in
                Canvas { ctx, size in
                    let transform = CGAffineTransform(translationX: size.width / 2 + offset.width,
                                                     y: size.height / 2 + offset.height)
                        .scaledBy(x: scale, y: scale)

                    // Draw edges
                    for edge in vm.edges {
                        guard let src = vm.nodes.first(where: { $0.id == edge.sourceId }),
                              let dst = vm.nodes.first(where: { $0.id == edge.targetId }) else { continue }
                        var path = Path()
                        path.move(to: src.position.applying(transform))
                        path.addLine(to: dst.position.applying(transform))
                        ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                    }

                    // Draw nodes
                    for node in vm.nodes {
                        let pt = node.position.applying(transform)
                        let r: CGFloat = 8
                        let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                        let c = node.type.color
                        ctx.fill(Circle().path(in: rect),
                                 with: .color(red: c.r, green: c.g, blue: c.b))
                        ctx.draw(
                            Text(node.label).font(.system(size: 9)).foregroundStyle(.secondary),
                            at: CGPoint(x: pt.x, y: pt.y + r + 2),
                            anchor: .top
                        )
                    }
                }
                .onChange(of: timeline.date) { _, _ in
                    vm.tick()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        offset = CGSize(width: dragStart.width + v.translation.width,
                                       height: dragStart.height + v.translation.height)
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { v in scale = max(0.25, min(4, v)) }
            )
            .onTapGesture { location in
                let size = geo.size
                let transform = CGAffineTransform(translationX: size.width / 2 + offset.width,
                                                  y: size.height / 2 + offset.height)
                    .scaledBy(x: scale, y: scale)
                guard let inv = transform.inverted() as CGAffineTransform? else { return }
                let localPt = location.applying(inv)
                let hit = vm.nodes.min(by: {
                    let d0 = distance($0.position, localPt)
                    let d1 = distance($1.position, localPt)
                    return d0 < d1
                })
                if let node = hit, distance(node.position, localPt) < 20 / scale {
                    onNavigate(node.id)
                }
            }
        }
        .navigationTitle("Graph")
        .toolbar {
            ToolbarItem {
                Button("Reset") {
                    offset = .zero; scale = 1; try? vm.load()
                }
            }
        }
        .onAppear { try? vm.load() }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x; let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

private extension CGAffineTransform {
    func inverted() -> CGAffineTransform? {
        guard self.isInvertible else { return nil }
        return self.inverted()
    }
}
```

> **Note:** `CGAffineTransform.inverted()` is a standard method — the extension above adds a nil-safe wrapper. In Swift, `CGAffineTransform.inverted()` returns non-optional, so simply use it directly: `let inv = transform.inverted()` and `location.applying(inv)`.

Replace the extension with:
```swift
// No extension needed — use directly:
// let inv = transform.inverted()
// location.applying(inv)
```

Update the `onTapGesture` to:
```swift
            .onTapGesture { location in
                let size = geo.size
                let transform = CGAffineTransform(translationX: size.width / 2 + offset.width,
                                                  y: size.height / 2 + offset.height)
                    .scaledBy(x: scale, y: scale)
                let inv = transform.inverted()
                let localPt = location.applying(inv)
                if let node = vm.nodes.min(by: { distance($0.position, localPt) < distance($1.position, localPt) }),
                   distance(node.position, localPt) < 20 / scale {
                    onNavigate(node.id)
                }
            }
```

And remove the `private extension CGAffineTransform` block entirely.

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 3: Run full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass (NoteStoreTests, WikiLinkParserTests, DailyNoteTests, UniversalSearchTests, GraphViewModelTests, and all pre-existing tests).

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/Notes/GraphView.swift
git commit -m "feat(notes): GraphView Canvas force-directed graph (slice 14)"
```

---

## Task 14: Update PLAN.md + final smoke test

**Files:**
- Modify: `PLAN.md`

- [ ] **Step 1: Mark Phase 2 slices as complete in PLAN.md**

In `PLAN.md`, find the Phase 2 section and update each slice checkbox:

Change:
```markdown
- [ ] **Slice 9 — Notes storage.**
- [ ] **Slice 10 — Editor.**
- [ ] **Slice 11 — Wiki-links + backlinks.**
- [ ] **Slice 12 — Daily notes + tags.**
- [ ] **Slice 13 — Search.**
- [ ] **Slice 14 — Graph view.**
```

To:
```markdown
- [x] **Slice 9 — Notes storage.**
- [x] **Slice 10 — Editor.**
- [x] **Slice 11 — Wiki-links + backlinks.**
- [x] **Slice 12 — Daily notes + tags.**
- [x] **Slice 13 — Search.**
- [x] **Slice 14 — Graph view.**
```

- [ ] **Step 2: Run full test suite**

```bash
swift test 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 3: Build the app**

```bash
xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build 2>&1 | grep -E "error:|warning:|Build succeeded"
```

Expected: `Build succeeded` (zero errors).

- [ ] **Step 4: Final commit**

```bash
git add PLAN.md
git commit -m "docs: mark Phase 2 slices 9-14 complete in PLAN.md"
```

---

## Self-Review Notes

**Spec coverage:**
- Slice 9 storage → Tasks 1+2+3 ✓
- Slice 10 editor → Tasks 4+5+6+7+8 ✓
- Slice 11 wiki-links → embedded in Tasks 2+5+7 ✓
- Slice 12 daily notes + tags → Tasks 9+10 ✓
- Slice 13 universal search → Task 11 ✓
- Slice 14 graph → Tasks 12+13 ✓

**Type consistency check:**
- `Note` used consistently across all tasks ✓
- `NoteStore.shared` used everywhere ✓
- `TaskStore.shared` added in Task 10; referenced in Task 11 ✓
- `GraphViewModel.tick()` (no params) called in `TimelineView.onChange` ✓
- `MainSelection.note(String)` and `MainSelection.notes(NotesFilter)` defined once in Task 8 ✓
- `NotesFilter` enum defined in Task 8, referenced in Tasks 9+10+11 ✓

**Known adjustments required during implementation:**
- `TranscriptStore` initializer signature — verify against actual file before Task 11 Step 4
- `MarkdownEditorView` coordinator method names — verify before Task 4 Step 2
- `TaskStore.fetchTasks(filter:)` method name — verify against `TaskStore.swift` before Task 10 Step 4
