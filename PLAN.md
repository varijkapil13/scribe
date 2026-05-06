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

- [~] **Slice 6 — Reminders.** `TaskReminderScheduler` wraps
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

- [ ] **Slice 8 — NL quick add + search + polish.** Parse
      "buy milk tomorrow 5pm #shopping !high" client-side: pull off
      `#tag`, `!high|!med|!low`, project via `+project`, and date phrases
      via `NSDataDetector` (Apple's data detector handles "tomorrow",
      "Friday 5pm", etc.). Add `tasks_fts` FTS5 over `title` + `notes`
      with insert/update/delete triggers. Wire up Cmd-F search, plus
      keyboard shortcuts: Cmd-N (new), Space (toggle complete on selection),
      Cmd-Backspace (delete with confirm), Cmd-↑/↓ (move).

### Phase 1 risks
- Notification entitlement under Hardened Runtime — sandbox is off, should
  work; verify in slice 6.
- Recurrence math timezone bugs — write tests around DST transitions.
- DB migrations must remain additive — keep the `eraseDatabaseOnSchemaChange`
  DEBUG flag aware that the dev DB will be wiped on schema diff.

---

## Phase 2 — Notes (Obsidian replacement)

### Slices

- [ ] **Slice 9 — Notes storage.** Migration v4: `notes(id, title, body,
      createdAt, updatedAt, isDailyNote, dailyDate?)`, `note_tags`,
      `note_links(sourceNoteId, targetNoteId, range)` for bidirectional
      navigation. `notes_fts` FTS5 over `title + body`. `NoteStore` CRUD +
      observation.

- [ ] **Slice 10 — Editor.** SwiftUI markdown editor. Investigate
      `MarkdownUI` for rendering, `NSTextView` wrapper for editing with
      live syntax highlighting (headings, bold, italic, code, lists, links).
      Two modes: **edit** and **preview**, toggle keyboardable.

- [ ] **Slice 11 — Wiki-links + backlinks.** Parse `[[title]]` on save,
      resolve to noteId or sessionId/taskId; persist edges in `note_links`.
      Click a link → navigate. Right panel shows backlinks (which notes /
      sessions / tasks reference this note). Autocomplete `[[` with
      fuzzy-matched candidate list.

- [ ] **Slice 12 — Daily notes + tags.** "Today's note" sidebar entry
      auto-creates a note dated today on first open. Calendar view to jump
      to past daily notes. Tag pane lists `#tag` occurrences across notes
      and tasks (shared namespace).

- [ ] **Slice 13 — Search.** Universal search over notes + tasks +
      transcripts. Cmd-Shift-F opens a quick-search palette; results
      grouped by type. Use the existing `segments_fts` plus new `notes_fts`
      and `tasks_fts`.

- [ ] **Slice 14 — Graph view.** Force-directed graph of notes / sessions
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
