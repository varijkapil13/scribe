# Scribe — Tasks & Notes Roadmap

This document captures the long-running plan for evolving Scribe into a single
personal app that replaces TickTick (tasks) and Obsidian (notes) **in addition
to** its existing meeting-transcript core. It is the source of truth across
sessions — update it as decisions land or scope changes.

## Status legend
- [ ] not started
- [~] in progress / branch open
- [x] merged

## High-level goals
1. Keep meeting-transcript capture as the strongest, most polished surface.
2. Add a first-class **task** layer (TickTick replacement) backed by SQLite.
3. Add a **notes** layer with markdown + wiki-links + backlinks (Obsidian
   replacement).
4. Cross-link everything: tasks ↔ notes ↔ sessions ↔ segments. Tags shared.
5. Optional in Phase 4: export/sync to a markdown folder so an existing
   Obsidian vault can still read the same notes if the user wants a fallback.

## Decisions made
- **No subtasks** in v1. (Drop `parentTaskId`.)
- **Convert button** for action item → task (no auto-creation on summary save).
- **Natural-language quick add** is required in v1 (e.g. "buy milk tomorrow 5pm").
- **No pomodoro / focus timer** in v1.
- Default branch is **`master`**. PRs are short, sliceable, and merge fast.
- Storage struct is named `TodoTask` (not `Task`) to avoid the constant
  collision with `_Concurrency.Task` in the UI layer.
- Tests run via **`swift test`** against `Package.swift`, not via the Xcode
  test scheme. The Scribe host app boots audio services on launch and the
  Xcode-hosted test bundle crashes during bootstrap; SwiftPM logic-only tests
  avoid this.
- Schema migrations are **additive** — never rewrite existing transcript
  tables.

## Architectural conventions
- Models in `Scribe/Storage/` — GRDB `FetchableRecord, PersistableRecord`.
- One store per major domain: `TranscriptStore` (sessions, segments,
  summaries, action items, entities), `TaskStore` (tasks/projects/tags),
  later `NoteStore`.
- ViewModels in `Scribe/UI/<Feature>/` — `@MainActor`, `@Published` state,
  reload on `NotificationCenter` events.
- Notification names: `extension Notification.Name` in `MainWindowView.swift`.
- Sidebar selection is a single enum (`MainSelection`) extended for new
  destinations; the detail pane switches on it.
- Logging: `Log.<subsystem>` from `Scribe/Utilities/Log.swift`.
- Project regen: `xcodegen` after adding/removing source files.

---

## Phase 1 — Tasks (TickTick replacement)

### Schema (added in Slice 1)
- `projects(id, name, color?, icon?, createdAt, sortOrder)`
- `tasks(id, title, notes, projectId?, priority?, dueAt?, remindAt?,
  recurrenceRule?, completedAt?, createdAt, updatedAt, sortOrder,
  sourceSessionId?, sourceActionItemId?)`
- `task_tags(taskId, tag)` — many-to-many
- `task_completions(id, taskId, completedAt)` — history for recurring tasks
- Indexes on `tasks.dueAt`, `tasks.projectId`, `tasks.completedAt`,
  `task_tags.tag`, `task_completions.taskId`

### Slices

- [x] **Slice 1 — Storage layer.** Migration v3, `TodoTask`/`Project`/
      `TaskTagRow`/`TaskCompletion`, `TaskStore` with CRUD, tag normalisation,
      reordering, ValueObservation, and filter queries (Inbox / Today /
      Upcoming / All / Completed / project / tag). Tests: 11 cases via
      `swift test`. PR #2.

- [x] **Slice 2 — Sidebar + minimal task list.** Extend `MainSelection` with
      `.tasks(TaskStore.Filter)`. New sidebar section "Tasks": Inbox,
      Today, Upcoming, All, Completed. Detail pane = vertical list grouped by
      date (Overdue / Today / Tomorrow / This week / Later / No date /
      Completed). Each row is a checkbox + title + due date chip with
      overdue tint. Quick-add field at the top creates an Inbox task on
      Return. ViewModel `TaskListViewModel` observes
      `TaskStore.observeTasks(filter:)`. Cmd-N focus + grouped-list
      keyboard shortcuts land in slice 8. PR open as
      `feat/tasks-slice-2-list-ui`.

- [x] **Slice 3 — Task editor pane.** Modal sheet on row tap (right-side
      inspector deferred). Edits title, notes, priority, due date,
      reminder, project, tags. Save on commit (Cmd-Return), Cancel
      discards. Toolbar exposes Duplicate + Delete (destructive with
      confirm). PR open as `feat/tasks-slice-3-editor-pane`.

- [x] **Slice 4 — Projects.** Project create / edit / delete sheet,
      sidebar Projects subsection below the smart filters with `+` button,
      drag-to-reorder rows (`onMove`), drop a task onto a project row to
      move it (`Transferable` payload), tag chips rendered under task
      titles. PR open as `feat/tasks-slice-4-projects`.

- [x] **Slice 5 — Action item → task bridge.** "Convert to task" button on
      each `ActionItemRow` in `TranscriptDetailView` pre-fills title /
      notes / priority and sets `sourceSessionId` + `sourceActionItemId`.
      Once converted the row's button flips to "Open task" and re-uses
      the existing `TaskEditorView` sheet (so editing / deleting / dup
      the linked task all work). Editor sheet shows a "Source: <session
      title>" row when `sourceSessionId` is set. PR open as
      `feat/tasks-slice-5-convert-action-item`.

- [x] **Slice 6 — Reminders.** `TaskReminderScheduler` wraps
      `UNUserNotificationCenter` behind a `TaskReminderScheduling`
      protocol so view models can inject a no-op for tests. Lazy
      authorization (requested first time `schedule(_:)` runs against
      a candidate task). Categories + actions ("Mark Done", "Snooze
      15 min") registered at launch via `AppDelegate`. Editor save,
      task delete, complete / uncomplete (incl. recurring re-arm)
      all schedule / cancel as appropriate. PR open as
      `feat/tasks-slice-6-reminders`.

- [x] **Slice 7 — Recurring tasks.** Minimal RRULE parser
      (`RecurrenceEngine`): `FREQ=DAILY|WEEKLY|MONTHLY`, `INTERVAL`,
      `BYDAY` (MO,TU,…). On complete, advance `dueAt` and clear
      `completedAt` while writing a row to `task_completions`. Picker UI
      for "Daily / Weekdays / Weekly on…/ Monthly on day N / Custom".
      Tests across DST boundaries.

- [~] **Slice 8 — NL quick add + search + polish.** New
      `QuickAddParser` strips `#tag`, `+project`, `!priority`, and date
      phrases (via `NSDataDetector`) out of the quick-add field; project
      hints resolve against the live project list, unknown names fall
      back to Inbox. Migration v5 adds a `tasks_fts` FTS5 virtual table
      backed by `tasks` with insert/update/delete sync triggers.
      `TaskStore.searchTasks(query:)` exposes prefix-matched bm25 search;
      `.searchable` in the task list flips the detail pane between
      grouped buckets and search results. Hidden keyboard shortcuts on
      the detail pane: Cmd-N focuses quick-add, Space toggles the
      focused row, Cmd-Backspace deletes with a confirmation dialog.
      Cmd-↑/↓ row reorder deferred (LazyVStack focus model needs work).
      PR open as `feat/tasks-slice-8-nl-fts-shortcuts`.

### Phase 1 risks
- Notification entitlement under Hardened Runtime — sandbox is off, should
  work; verify in slice 6.
- Recurrence math timezone bugs — write tests around DST transitions.
- DB migrations must remain additive — keep the `eraseDatabaseOnSchemaChange`
  DEBUG flag aware that the dev DB will be wiped on schema diff.

---

## Phase 2 — Notes (Obsidian replacement)

### Slices

- [x] **Slice 9 — Notes storage.** Migration v4: `notes(id, title, body,
      createdAt, updatedAt, isDailyNote, dailyDate?)`, `note_tags`,
      `note_links(sourceNoteId, targetNoteId, range)` for bidirectional
      navigation. `notes_fts` FTS5 over `title + body`. `NoteStore` CRUD +
      observation.

- [x] **Slice 10 — Editor.** SwiftUI markdown editor. Investigate
      `MarkdownUI` for rendering, `NSTextView` wrapper for editing with
      live syntax highlighting (headings, bold, italic, code, lists, links).
      Two modes: **edit** and **preview**, toggle keyboardable.

- [x] **Slice 11 — Wiki-links + backlinks.** Parse `[[title]]` on save,
      resolve to noteId or sessionId/taskId; persist edges in `note_links`.
      Click a link → navigate. Right panel shows backlinks (which notes /
      sessions / tasks reference this note). Autocomplete `[[` with
      fuzzy-matched candidate list.

- [x] **Slice 12 — Daily notes + tags.** "Today's note" sidebar entry
      auto-creates a note dated today on first open. Calendar view to jump
      to past daily notes. Tag pane lists `#tag` occurrences across notes
      and tasks (shared namespace).

- [x] **Slice 13 — Search.** Universal search over notes + tasks +
      transcripts. Cmd-Shift-F opens a quick-search palette; results
      grouped by type. Use the existing `segments_fts` plus new `notes_fts`
      and `tasks_fts`.

- [x] **Slice 14 — Graph view.** Force-directed graph of notes / sessions
      / tasks linked by wiki-links and source references.
      Probably last because it is expensive and easy to skip.

### Phase 2 risks
- SwiftUI's text-editing affordances are weak. The editor is the time sink.
  Pick a library (`MarkdownUI`, `Down`) before writing one from scratch.
- Wiki-link resolution must stay incremental — never re-parse the whole
  vault on save.

---

## Phase 3 — Cross-linking
Once tasks and notes both exist, wire the joins:
- A meeting session shows its **summary**, **action items / linked tasks**,
  and **notes that reference it**.
- A task shows its **source session / action item** and **notes that
  reference it**.
- A note's right panel always shows backlinks regardless of source type.
- Tag pane is a unified taxonomy across all three entities.

### Phase 3 slices — Meeting Notes (sessions ↔ notes)

- [x] **Slice 15 — Storage + migration.** Migration
      `v10_session_noteId` adds nullable `sessions.noteId` column +
      `sessions_noteId_idx`. `Session.noteId: String?` with Codable
      round-trip. `TranscriptStore.bindSession/fetchSessions/observeSessions(forNoteId:)`.
      `NoteStore.deleteNote` sweeps `sessions.noteId → NULL` so
      transcripts survive note deletion. Tests in
      `SessionNoteIdMigrationTests`, `TranscriptStoreNoteBindingTests`,
      and `DatabaseIntegrationTests`.

- [x] **Slice 16 — Sessions strip (read-only) in `NoteDetailView`.**
      `NoteDetailViewModel` observes
      `TranscriptStore.observeSessions(forNoteId:)`.
      `NoteSessionsStrip` renders a chip per linked session.
      `NoteSessionAutoSection` renders that session's summary, action
      items (with the existing "Convert to task" flow), and entity
      chips by reusing `TranscriptDetailViewModel`.

- [x] **Slice 17 — In-note recording.** "+ New recording" button on the
      strip starts a recording bound to the open note via
      `AppState.startSession(title:noteId:)`. `NoteLiveRecordingPane`
      shows the live transcript inline above the freeform editor while
      `AppState.currentSessionId` belongs to this note.

- [x] **Slice 18 — Global Record auto-binds.** `AppDelegate.startRecording`
      reads `AppState.currentSelection`. With a note open, the new
      session binds to it; otherwise `AppDelegate.resolveNoteContext`
      auto-creates a "Meeting on <date>" note and posts
      `.scribeRequestNavigateToNote` so the sidebar switches to the new
      note.

- [x] **Slice 19 — Retrofit toolbar.** "Move to note" menu on
      `TranscriptDetailView` lets existing transcripts bind to a new or
      existing note, or unbind. `MoveToNotePicker` sheet provides a
      live-filtered note picker.

### Phase 3 follow-ups

- [x] **Note markdown export.** `NoteMarkdownExporter` + Export toolbar
      button on `NoteDetailView`. Emits the freeform body plus a
      "## Linked recordings" tail with summary / action items /
      Mentioned entities (grouped People / Organizations / Places /
      Dates) per bound session. Tests cover all five cases.

### Rich Editor Phase 2 follow-ups

- [ ] **Split `MarkdownEditorView.swift`.** The file is now ~1500 lines
      mixing the SwiftUI representable, AppKit subclass, formatter, and
      attachment cells. Split into:
      `MarkdownEditorView.swift` (SwiftUI representable + Coordinator),
      `MarkdownNSTextView.swift` (AppKit subclass with smart Enter /
      Tab / drag / mouse), `MarkdownFormatter.swift` (the line walk +
      table styling), and a small file per attachment cell type. Not a
      blocker — reviewer-flagged as quality follow-up.
- [ ] **Table cell tab navigation.** The Phase 2 spec mentioned smart
      Tab inside a table moving to the next cell. Currently Tab inside
      a table falls through to the existing list-indent behaviour. Add
      detection: if the cursor is inside a `MarkdownTable.detect` block,
      Tab jumps to the next `|`-bounded cell on the same row (or first
      cell of the next row at end-of-row); Shift-Tab reverses.
- [ ] **`applyFormatting` profiling.** The full pass re-runs on every
      selection change (`textViewDidChangeSelection`). At current note
      sizes it's fine; profile once notes get multi-KB bodies.

## Phase 4 — Polish
- Global hotkey for **Quick Capture** (use existing `KeyboardShortcuts`
  package). Prompt asks: capture as note, task, or both.
- Calendar view (Tasks + daily notes overlay).
- Markdown export of notes to a folder so Obsidian can also read them
  (optional dual-store mode).
- Onboarding screen for first launch.
- Accessibility audit (VoiceOver, reduce motion, dynamic type).

---

## How to resume after a break
1. Pull `master`. Read this file from top to bottom.
2. Find the last `[x]` and the next `[ ]` in Phase 1 — that is where
   to start.
3. Open the existing PRs (`gh pr list --base master`) to see in-flight work.
4. Run the smoke-test commands below to confirm the local tree is healthy.

### Smoke-test commands
```bash
# Regenerate the Xcode project after adding/removing files
xcodegen

# Build the macOS app
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build

# Run unit tests (logic-only via SwiftPM)
swift test

# Run a specific test class
swift test --filter TaskStoreTests
```

## Open questions (revisit before each slice)
- Do we want sub-projects / nested projects? (Out of scope for now.)
- Per-task attachments (images, files)? (Probably Phase 4.)
- iCloud sync? Big spec. Not until everything else is solid.
- Mobile companion? Not planned.
