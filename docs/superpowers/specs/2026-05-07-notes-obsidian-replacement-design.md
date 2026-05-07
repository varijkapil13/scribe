# Phase 2 Design — Notes (Obsidian Replacement)

**Date:** 2026-05-07  
**Status:** Approved  
**Branch:** `feat/notes-phase2` (all slices land here; each slice must keep app buildable)

---

## Goals

Add a first-class notes layer to Scribe that replaces Obsidian for personal note-taking:

- Markdown editor with Bear-style live syntax highlighting (no mode-switch)
- Wiki-links (`[[title]]`) with backlinks panel
- Daily notes with calendar navigation
- Unified tag namespace across notes and tasks
- Universal search across notes + tasks + transcripts
- Force-directed graph view of note/session/task relationships

All data stays local (SQLite). No cloud sync. No new dependencies.

---

## Architecture

```
Scribe/
├── Storage/
│   ├── Note.swift              # Note + NoteLinkRow + NoteTagRow models
│   └── NoteStore.swift         # CRUD, observation, backlinks, daily note, tag queries
├── UI/
│   ├── DesignSystem/
│   │   └── MarkdownEditorView.swift   # moved from UI/Tasks/ (shared base)
│   ├── Notes/
│   │   ├── NoteListView.swift
│   │   ├── NoteListViewModel.swift
│   │   ├── NoteDetailView.swift       # editor left + backlinks right
│   │   ├── NoteDetailViewModel.swift
│   │   ├── NoteEditorView.swift       # wraps MarkdownEditorView + [[...]] overlay
│   │   ├── NoteBacklinksView.swift    # right panel
│   │   ├── DailyNoteView.swift
│   │   ├── DailyNoteViewModel.swift
│   │   ├── NoteCalendarView.swift
│   │   └── GraphView.swift            # force-directed Canvas graph (Slice 14)
│   └── MainWindow/
│       └── MainWindowView.swift       # extended with Notes sidebar section
```

---

## Slice 9 — Notes Storage

### Migration v6

```sql
CREATE TABLE notes (
    id TEXT NOT NULL PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL,
    isDailyNote INTEGER NOT NULL DEFAULT 0,
    dailyDate TEXT   -- "YYYY-MM-DD", non-null only when isDailyNote=1
);

CREATE INDEX notes_dailyDate_idx ON notes (dailyDate);
CREATE INDEX notes_updatedAt_idx ON notes (updatedAt);

CREATE TABLE note_tags (
    noteId TEXT NOT NULL REFERENCES notes ON DELETE CASCADE,
    tag TEXT NOT NULL,
    PRIMARY KEY (noteId, tag)
);
CREATE INDEX note_tags_tag_idx ON note_tags (tag);

CREATE TABLE note_links (
    sourceNoteId TEXT NOT NULL REFERENCES notes ON DELETE CASCADE,
    targetNoteId TEXT NOT NULL REFERENCES notes ON DELETE CASCADE,
    anchorText TEXT NOT NULL,
    PRIMARY KEY (sourceNoteId, targetNoteId, anchorText)
);
CREATE INDEX note_links_targetNoteId_idx ON note_links (targetNoteId);

CREATE VIRTUAL TABLE notes_fts USING fts5(
    title, body,
    content='notes',
    content_rowid='rowid'
);

-- Sync triggers (same pattern as tasks_fts)
CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;
CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
END;
CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;
```

### Models

```swift
struct Note: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: String       // UUID string
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isDailyNote: Bool
    var dailyDate: String?  // "YYYY-MM-DD"
}

struct NoteLinkRow: Codable, FetchableRecord, PersistableRecord {
    var sourceNoteId: String
    var targetNoteId: String
    var anchorText: String   // the [[text]] that created this link
}

struct NoteTagRow: Codable, FetchableRecord, PersistableRecord {
    var noteId: String
    var tag: String
}
```

### NoteStore API

```swift
final class NoteStore {
    // CRUD
    func createNote(_ note: Note, tags: [String]) throws
    func updateNote(_ note: Note, tags: [String]) throws  // also rewrites note_links
    func deleteNote(id: String) throws
    func fetchNote(id: String) throws -> Note?

    // Observation
    func observeNotes() -> AnyPublisher<[Note], Error>
    func observeNote(id: String) -> AnyPublisher<Note?, Error>

    // Daily notes
    func dailyNote(for date: Date) throws -> Note  // creates if absent

    // Tags
    func tags(for noteId: String) throws -> [String]
    func allNoteTags() throws -> [String]  // for unified tag pane

    // Backlinks
    func backlinks(for noteId: String) throws -> [Note]

    // Wiki-link resolution
    func resolveTitle(_ title: String) throws -> Note?  // case-insensitive

    // Search (used by Slice 13 universal search)
    func searchNotes(query: String) throws -> [Note]
}
```

### Tests (Slice 9)

- CRUD round-trips
- Tag normalization (trim, lowercase)
- Daily note idempotency (same date → same note)
- `backlinks(for:)` returns correct sources after save
- FTS search returns ranked results
- Cascade delete cleans note_tags and note_links

---

## Slice 10 — Editor UI

### MarkdownEditorView refactor

Move `Scribe/UI/Tasks/MarkdownEditorView.swift` → `Scribe/UI/DesignSystem/MarkdownEditorView.swift`.  
Update `project.yml` accordingly. No behavior change for the Tasks editor.

### NoteEditorView

Wraps `MarkdownEditorView` and adds:

- Coordinator override: after each keystroke, scan the attributed string for `[[...]]` spans and apply a distinct tint color + underline attribute (no separate rendering mode)
- On `[[` typed: show `WikiLinkPopup` — a `List` overlay anchored below the cursor, filtered by the characters typed after `[[`, populated via `NoteStore.resolveTitle` prefix scan
- `Cmd-Shift-P`: toggle a read-only preview sheet (renders body as styled HTML via `NSAttributedString` markdown init)

### NoteDetailView

```
┌────────────────────────────────────────┬──────────────────────┐
│  NoteEditorView (flexible width)       │  NoteBacklinksView   │
│                                        │  (fixed 240pt)       │
│                                        │  ─ Notes linking here│
│                                        │  ─ Sessions          │
│                                        │  (Slice 13 extension)│
└────────────────────────────────────────┴──────────────────────┘
```

Keyboard shortcuts:
- `Cmd-N` — create new note (focus title field)
- `Cmd-Return` — save note
- `Esc` — discard unsaved changes (with confirm if dirty)
- `Cmd-Shift-P` — preview toggle

### NoteListView

Rows: title (derived from first `# Heading` line or first 60 chars of body), date snippet, tag chips. Grouped by: Today / This Week / Older. Search field triggers `NoteStore.searchNotes`.

### Sidebar extension

New "Notes" section in `MainWindowView` sidebar below Tasks:
- **All Notes** (`.notes(.all)`)
- **Today** (`.notes(.today)` — today's daily note)
- **Daily Notes** (`.notes(.daily)` — calendar picker)
- **Tags** (`.notes(.tag(String))`)
- **Graph** (`.notes(.graph)`)

---

## Slice 11 — Wiki-links + Backlinks

### Save-time parsing

`NoteStore.updateNote(_:tags:)` runs a regex over `body`:

```
\[\[([^\[\]]+)\]\]
```

For each match:
1. Try `resolveTitle(match)` → noteId
2. If resolved: upsert `NoteLinkRow(sourceNoteId, targetNoteId, anchorText: match)`
3. Delete all prior `note_links` for this `sourceNoteId` then reinsert found links

Unresolved links are stored as-is in body text (no broken-link error). When a note is later created whose title matches, the next save of the source note will resolve it.

### Click navigation

`NoteEditorView` coordinator intercepts click on `[[...]]` span, extracts anchor text, calls `onNavigate(title:)` closure. `NoteDetailViewModel` resolves title → noteId → sets `MainSelection.note(id)`.

### Backlinks panel

`NoteBacklinksView` queries `NoteStore.backlinks(for: currentNoteId)`. Rows show source note title; clicking navigates. Empty state: "No notes link here yet."

### Autocomplete popup

`WikiLinkPopup`: floating `List` with max 6 rows, keyboard-navigable. Accepts `Tab` or `Return` to complete, `Esc` to dismiss. Populated by `NoteStore.resolveTitle` prefix query (FTS5 prefix on `title`).

---

## Slice 12 — Daily Notes + Unified Tags

### Daily notes

- Sidebar "Today" entry calls `NoteStore.dailyNote(for: Date())` on tap
- `DailyNote` title format: `"Daily Note – May 7, 2026"`
- `NoteCalendarView`: month grid, days with existing daily notes shown with dot indicator. Tap → `NoteStore.dailyNote(for: selectedDate)`

### Unified tag pane

Sidebar "Tags" section lists tags from both `note_tags` and `task_tags` (de-duplicated, sorted). Selecting a tag sets `MainSelection` to a combined filter showing both matching notes and tasks in split sections.

---

## Slice 13 — Universal Search

### Search palette

- `Cmd-Shift-F` registered via `KeyboardShortcutManager` / `KeyboardShortcuts`
- `.overlay` sheet in `MainWindowView`
- Single `SearchViewModel` issues three concurrent GRDB queries:
  - `NoteStore.searchNotes(query:)` → `[Note]`
  - `TaskStore.searchTasks(query:)` → `[TodoTask]` (existing)
  - `TranscriptStore.searchSegments(query:)` → `[Segment]` (existing FTS)
- Results assembled into `[SearchResultSection]` (Notes / Tasks / Transcripts)
- Each result row has icon, title, snippet. Tap → close palette + navigate

### SearchViewModel

```swift
@MainActor final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var sections: [SearchResultSection] = []
    func search() async  // debounced 150ms
}

struct SearchResultSection: Identifiable {
    let id: String       // "notes" | "tasks" | "transcripts"
    let title: String
    let results: [SearchResult]
}

struct SearchResult: Identifiable {
    let id: String
    let title: String
    let snippet: String
    let destination: MainSelection
}
```

---

## Slice 14 — Graph View

### Implementation

Pure SwiftUI `Canvas` + `TimelineView` for animation. No SpriteKit.

### Data

`GraphViewModel` builds:
- **Nodes**: all notes + all sessions + all tasks that have `sourceSessionId` or a `note_links` reference
- **Edges**: `note_links` rows; `tasks.sourceSessionId` → session; future `tasks.sourceNoteId` (added in Phase 3 cross-linking)
- Node colors: note=systemBlue, session=systemGreen, task=systemOrange

### Physics

Simple Euler integration at 60fps:
- Repulsion: inverse-square between all node pairs (Barnes-Hut approximation not needed at this scale)
- Spring: Hooke's law per edge (rest length 120pt)
- Damping: velocity × 0.85 each tick
- Settle detection: stop `TimelineView` updates when max velocity < 0.5pt/s

### Interaction

- `DragGesture` on canvas: pan offset
- `MagnificationGesture`: zoom (0.25×–4×)
- Tap detection: find nearest node within 20pt of tap location → navigate
- Node label: note title (truncated 20 chars), session date, task title

### Canvas draw

Each frame: draw edges (gray lines), then nodes (filled circles r=8), then labels below nodes. Selected node highlighted with accent ring.

---

## Error Handling

- `NoteStore` operations throw; callers catch and surface via `@Published var errorMessage: String?` on ViewModels (existing pattern from `TaskListViewModel`)
- Wiki-link resolution failures are silent (unresolved links render as plain text)
- Graph view with 0 nodes shows an empty-state message

---

## Testing Strategy

- **Slice 9**: `NoteStoreTests.swift` — 12+ unit tests via `swift test`
- **Slice 10**: No UI tests; `MarkdownEditorView` move is a file-level refactor
- **Slice 11**: `WikiLinkParserTests.swift` — test regex extraction, title resolution, cascade delete on note rename
- **Slice 12**: `DailyNoteTests.swift` — idempotency, title format, calendar date mapping
- **Slice 13**: `UniversalSearchTests.swift` — multi-store fan-out, result grouping, empty-query guard
- **Slice 14**: `GraphViewModelTests.swift` — node/edge construction from mock store data, settle detection

All tests run via `swift test` (same as existing suite — no Xcode test scheme).

---

## Constraints & Risks

| Risk | Mitigation |
|------|-----------|
| Wiki-link save rewrites all links for source note — could be slow on large bodies | Rewrite is bounded by number of `[[` occurrences; acceptable at typical note sizes |
| Canvas graph perf with 1000+ nodes | Settle detection stops animation; static redraw on navigate is instant |
| `MarkdownEditorView` move breaks Tasks build | Move in Slice 10 Step 1; regenerate `project.yml` before any other change |
| FTS query on `notes_fts` while migration is in progress | GRDB migrations run synchronously before app UI appears; no race |

---

## Open Questions (deferred)

- Cross-entity wiki-links (`[[session title]]`, `[[task title]]`) — Phase 3
- Note attachments (images, files) — Phase 4
- iCloud sync — not planned
- Note versioning / history — not planned
