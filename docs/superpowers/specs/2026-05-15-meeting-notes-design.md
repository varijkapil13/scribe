# Meeting Notes — Design (Phase 3, Slice 15+)

**Date:** 2026-05-15
**Status:** Approved

## Goal

Combine Scribe's existing transcript capture and note-taking surfaces into a single workspace: a **Note** can own one or many **recording sessions** and surface the AI-derived summary, action items, and entity/topic analysis from those sessions alongside the user's freeform writing.

The transcript stays in `TranscriptStore` as source of truth. Notes act as a workspace that binds together (a) freeform user writing and (b) per-session auto-generated enrichment.

## Non-goals (YAGNI)

- No quoted-transcript segment embedding inside `notes.body`.
- No live AI rewrite of freeform notes against the transcript ("merge and polish").
- No many-to-many sessions↔notes. A session belongs to at most one note.
- No editing of the auto-generated sections inline. The user owns `notes.body`; the auto-section is read-only and refreshed from the transcript pipeline.
- No combined-across-sessions summary. Multi-session notes show one auto-block per session.

## Design

### 1. Data model

One additive migration.

**Migration v6:**

```sql
ALTER TABLE sessions ADD COLUMN noteId TEXT;
CREATE INDEX idx_sessions_noteId ON sessions(noteId);
```

| Column | Semantics |
|---|---|
| `sessions.noteId` | Nullable. When set, links this session to a single Note. |

FKs are not enforced via `ALTER TABLE` in this codebase (matches the `notes.notebookId` pattern). `NoteStore.deleteNote(id:)` is extended to sweep `UPDATE sessions SET noteId = NULL WHERE noteId = ?` before deleting the note, so transcripts survive note deletion.

Backfill: existing sessions stay `NULL` (unattached). They can be bound retroactively via slice 19.

`Session` Swift struct gains the optional field; encode/decode are automatic via Codable.

### 2. Storage layer

**`TranscriptStore` additions:**

```swift
func bindSession(_ sessionId: String, toNote noteId: String?) throws
func fetchSessions(forNoteId noteId: String) throws -> [Session]
func observeSessions(forNoteId noteId: String) -> AnyPublisher<[Session], Error>
```

**`NoteStore` additions:**

```swift
func sessions(for noteId: String) throws -> [Session]   // convenience that delegates to TranscriptStore
```

No new entry points on `NoteStore.createNote` — binding is a separate call. Tests cover bind/unbind, cascade-on-delete-note, and observation.

### 3. Note detail view — Sessions strip

`NoteDetailView` gains a **Sessions strip** rendered between the header and the editor body.

**Layout:**

```
┌─ Header (title / metadata / notebook chip) ────────────┐
├─ Sessions strip ───────────────────────────────────────┤
│  [Session 1 chip]  [Session 2 chip]  [+ New recording] │
├─ Per-session auto-sections (expanded chip only) ───────┤
│  ▼ Session 1 — 2026-05-15 · 32m                        │
│     Summary  |  Action items  |  Entities & topics     │
├─ Freeform editor (existing NoteEditorView) ────────────┤
│  (user writes here)                                    │
├─ Backlinks bar (existing) ─────────────────────────────┤
└────────────────────────────────────────────────────────┘
```

**Session chip:** title (or "Untitled Session"), date, duration, status indicator (recording dot / processing spinner / done check). Tap to expand its auto-section inline beneath the strip. Only one expanded at a time.

**Auto-section contents** (read-only, sourced from existing tables):
- **Summary** — `meeting_summaries` row for this session, rendered as the existing summary view component.
- **Action items** — `action_items` for this session. Each row keeps the existing **Convert to task** / **Open task** button intact, with `sourceSessionId` already set.
- **Entities & topics** — `extracted_entities` rendered as "Mentioned" chips below the action items. Distinct from user-set `note_tags`.

If no summary has been generated yet, show an "Generate summary" button that triggers the existing `MeetingSummarizer.summarize(sessionId:)` pipeline. Same for analysis.

**`+ New recording` button:** starts a new session bound to this note (see §5).

**Files:**
- New: `Scribe/UI/Notes/NoteSessionsStrip.swift` — the strip + chip.
- New: `Scribe/UI/Notes/NoteSessionAutoSection.swift` — the expanded per-session block. Reuses existing summary/action-item/insight subviews from `TranscriptDetailView` (extract them into shared `Scribe/UI/Shared/` if not already standalone).
- Modified: `Scribe/UI/Notes/NoteDetailView.swift` — insert strip; bind ValueObservation on linked sessions.
- Modified: `Scribe/UI/Notes/NoteDetailViewModel.swift` — `@Published var sessions: [Session]`, subscribe to `TranscriptStore.observeSessions(forNoteId:)`.

### 4. Live recording inside a Note

When `+ New recording` is tapped from inside a Note, the detail pane switches into **live recording mode** for that note. The Note remains selected in the sidebar; the detail pane shows:

```
┌─ Header ──────────────────────────────────────────────┐
├─ Sessions strip (new in-progress chip pulsing) ───────┤
├─ LIVE TRANSCRIPT pane (collapsible, top half) ────────┤
│  ⏺ Recording · 00:42                                  │
│  You: …                                               │
│  Remote: …                                            │
├─ Freeform editor (lower half — user types here) ──────┤
└───────────────────────────────────────────────────────┘
```

User can type into the freeform editor while transcription runs. Live transcript pane reuses the existing live-session view (already implemented for the `.live` selection); it's lifted into a reusable subview.

**Stop** ends the session via existing `AppState.stopSession()`. The in-progress chip flips to "processing" then "done" as summarisation/analysis complete. Auto-section under that chip becomes available.

**Files:**
- New: `Scribe/UI/Notes/NoteLiveRecordingPane.swift` — wraps the existing live transcript view.
- Modified: `Scribe/UI/MainWindow/MainWindowView.swift` — detail switch for `.note(id)` checks `AppState.isTranscribing && currentSessionId.noteId == id` and renders live pane above the freeform editor.

### 5. Global Record auto-binds

The existing global Record action (hero button + ⇧⌘R shortcut) needs to learn about Notes.

**Behaviour:**

| Context when Record pressed | Result |
|---|---|
| A Note is open in the detail pane | New session is bound to that note. Detail pane stays on the note; live pane appears (§4). |
| Anywhere else (transcript list, tasks, settings…) | A new "Meeting on \<datetime>" Note is auto-created. Session is bound to it. Sidebar selection switches to `.note(newId)`. |

Implementation: `AppDelegate.startRecording()` queries `MainSelection.current`. If `.note(id)`, pass `noteId` into `AppState.startSession(title:noteId:)`. Otherwise call `NoteStore.createNote(title: defaultTitle)` first, then `startSession(title:, noteId: newNote.id)`.

`AppState.startSession` gains a `noteId: String?` parameter and writes it onto the session immediately after `transcriptStore.createSession(title:)` via `bindSession(_:toNote:)`.

**Files:**
- Modified: `Scribe/App/AppDelegate.swift` — read selection, decide note resolution before calling `startSession`.
- Modified: `Scribe/App/AppState.swift` — `startSession(title:noteId:)`.

### 6. Retrofit existing transcripts

`TranscriptDetailView` toolbar gains a **"Move to note…"** menu:

- **New note** — creates a Note titled from the session, binds, opens that note.
- **Existing note…** — fuzzy picker over all notes; binds, opens that note.
- **Unbind** — only shown when `session.noteId != nil`. Sets it to `NULL`.

**Files:**
- Modified: `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift` — menu in toolbar.
- New: `Scribe/UI/TranscriptViewer/MoveToNotePicker.swift` — picker sheet.

### 7. Cross-linking surfaces

These come for free once §1–§6 are in place; no additional schema needed:

- Tasks created via "Convert to task" from a note-bound session already carry `sourceSessionId`. The Note's Sessions strip surfaces them implicitly via the action-items view.
- Backlinks from other notes still work; `[[Meeting on 2026-05-15]]` wiki-links resolve to the auto-titled meeting note.
- Markdown export (existing exporters) concatenates: `notes.body` + a generated tail section "## Linked recordings" with summaries/action items inlined.

## File summary

| File | Change |
|---|---|
| `Scribe/Storage/DatabaseManager.swift` | Migration v6: add `sessions.noteId`, index |
| `Scribe/Storage/Session.swift` | Add `noteId: String?` |
| `Scribe/Storage/TranscriptStore.swift` | `bindSession(_:toNote:)`, `fetchSessions(forNoteId:)`, `observeSessions(forNoteId:)` |
| `Scribe/Storage/NoteStore.swift` | `sessions(for:)` convenience; extend `deleteNote(id:)` to sweep `sessions.noteId` to NULL |
| `Scribe/App/AppState.swift` | `startSession(title:noteId:)` parameter |
| `Scribe/App/AppDelegate.swift` | Resolve note from selection before recording |
| `Scribe/UI/Notes/NoteDetailView.swift` | Insert Sessions strip; live pane when active |
| `Scribe/UI/Notes/NoteDetailViewModel.swift` | Observe linked sessions |
| **New** `Scribe/UI/Notes/NoteSessionsStrip.swift` | Chips + "+ New recording" button |
| **New** `Scribe/UI/Notes/NoteSessionAutoSection.swift` | Per-session summary / action items / entities block |
| **New** `Scribe/UI/Notes/NoteLiveRecordingPane.swift` | Live transcript view for in-note recording |
| `Scribe/UI/MainWindow/MainWindowView.swift` | Detail switch on `.note(id)` shows live pane when recording for that note |
| `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift` | "Move to note…" toolbar menu |
| **New** `Scribe/UI/TranscriptViewer/MoveToNotePicker.swift` | Picker sheet |
| `Scribe/Export/*` | Markdown/text/JSON exporters append "Linked recordings" tail when a note has sessions |

No new Swift package dependencies.

## Slicing

| # | Slice | Output |
|---|---|---|
| 15 | Storage + migration | Migration v6, `Session.noteId`, `TranscriptStore` bind/observe APIs, tests. No UI change. |
| 16 | Sessions strip (read-only) | `NoteSessionsStrip` + per-session auto-section in `NoteDetailView`. Bound to existing sessions only — no recording entry yet. Manual bind via SQL or test fixture. |
| 17 | `+ New recording` from a Note | Button in strip; recording starts bound to the open note. Live pane embeds in the note detail. |
| 18 | Global Record auto-binds | Hero button / ⇧⌘R uses open Note context, or auto-creates a "Meeting on …" note when no note is open. |
| 19 | Retrofit | "Move to note…" toolbar menu on `TranscriptDetailView`. Markdown export tail section. |

Each slice ships as its own PR. Slices 17+ are demoable only after 16 lands.

## Risks

- **Migration v6 on `eraseDatabaseOnSchemaChange` DEBUG flag** — dev DB wipe on schema diff is expected; document for the user before they pull.
- **Live pane focus split** — typing notes while live transcript streams may cause selection/scroll fights. The freeform editor must own keyboard focus by default; the live pane is a scrollable read-only region.
- **Live pane reuse** — the existing live-session view is tied to `MainSelection.live` in `MainWindowView`. Lifting it out cleanly is a small refactor; if it proves invasive, slice 17 may grow.
- **Auto-titling** — "Meeting on 2026-05-15 14:32" wiki-links work but are ugly. Acceptable for v1; renaming the note is one click.
- **Per-session vs combined summary** — locked to per-session per design call. Re-evaluate if multi-session notes become common.

## Open questions (revisit before each slice)

- Should "Generate summary" on the auto-section trigger immediately on Stop, or stay manual? Current `AppState.stopSession` already runs auto-analysis / auto-summarisation if enabled in Settings — keep that behaviour, no new flag.
- Should action-items extracted from a note-bound session inherit the note's tags? Out of scope for now; revisit in Phase 4 polish.
