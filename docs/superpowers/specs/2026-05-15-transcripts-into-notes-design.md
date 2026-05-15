# Transcripts-into-Notes — Design

**Date:** 2026-05-15
**Status:** Approved

## Goal

Eliminate "transcript" as a standalone navigation concept. Every recording session belongs to exactly one Note. The sidebar's Transcripts section disappears; transcripts are reached through their owning Note.

This is a follow-up to the Meeting Notes work (Phase 3, slices 15–19) on the same branch. That work made sessions *optionally* belong to a note. This change makes the binding mandatory and collapses the sidebar accordingly.

## Non-goals (YAGNI)

- Don't redesign the rich transcript view. `TranscriptDetailView`'s segment list, summarize/analyze toolbar, select+move, and export functionality stay — only the access pattern changes.
- Don't merge `TranscriptDetailView` into `NoteDetailView`. Keep the file as-is; reach it via a sheet from the note.
- Don't enforce NOT NULL at the SQL layer (SQLite can't `ALTER TABLE … ALTER COLUMN`). The contract is enforced in Swift; backfill guarantees no NULL rows exist.
- Don't change the MCP `transcripts://recent` resource — that's an external API surface, unaffected by sidebar/UI changes.

## Design

### 1. Data backfill — migration `v11_session_noteId_backfill`

```swift
migrator.registerMigration("v11_session_noteId_backfill") { db in
    // For every session without a noteId, create a Note titled from the
    // session and bind. After this migration, sessions.noteId is non-NULL
    // for every row (enforced by app-level API thereafter).
    let orphans = try Row.fetchAll(db, sql: """
        SELECT id, title, createdAt FROM sessions WHERE noteId IS NULL
        """)
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    for row in orphans {
        let sessionId: String = row["id"]!
        let sessionTitle: String = row["title"] ?? ""
        let createdAt: Date = row["createdAt"] ?? Date()
        let noteTitle = sessionTitle.isEmpty
            ? "Meeting on \(formatter.string(from: createdAt))"
            : sessionTitle
        let noteId = UUID().uuidString
        try db.execute(sql: """
            INSERT INTO notes (id, title, body, createdAt, updatedAt, isDailyNote, dailyDate, notebookId)
            VALUES (?, ?, '', ?, ?, 0, NULL, NULL)
            """, arguments: [noteId, noteTitle, createdAt, Date()])
        try db.execute(sql: "UPDATE sessions SET noteId = ? WHERE id = ?",
                       arguments: [noteId, sessionId])
    }
}
```

This runs once per DB. New sessions go through `TranscriptStore.createSession` which (post-change) requires a non-optional `noteId`.

### 2. Storage contract change

**`TranscriptStore.createSession(title:noteId:)`** — `noteId` becomes a required parameter:

```swift
@discardableResult
func createSession(title: String, noteId: String) throws -> Session {
    var session = Session(title: title, noteId: noteId)
    try db.write { try session.insert($0) }
    return session
}
```

Every caller must pass a noteId. The previous `bindSession` API stays (because the rich `TranscriptDetailView` still has rebind-not-applicable code paths to remove).

**`NoteStore.deleteNote` cascade change** — deleting a note now also deletes its sessions (and through the existing FK cascade, their segments / summaries / action items / entities). Tasks with `sourceSessionId` set to a deleted session keep their existing `ON DELETE SET NULL` behaviour.

```swift
func deleteNote(id: String) throws {
    try db.write { database in
        // Delete sessions owned by this note. The session row's FK cascades
        // wipe segments / meeting_summaries / action_items / extracted_entities.
        // Tasks.sourceSessionId is ON DELETE SET NULL so tasks survive.
        try database.execute(
            sql: "DELETE FROM sessions WHERE noteId = ?",
            arguments: [id]
        )
        _ = try Note.deleteOne(database, key: id)
    }
}
```

This replaces the previous sweep-to-NULL behaviour from slice 15.4. The rationale: if transcripts are *part of* the note, deleting the note must take the transcript with it. Anything else surprises the user.

### 3. UI changes

**Sidebar** (`Scribe/UI/MainWindow/MainWindowView.swift`):
- The `Section { … } header: { "Transcripts" }` block is removed entirely (lines 404–436 currently). The `transcriptsExpanded` `@State` and `viewModel: TranscriptListViewModel` are removed.
- `TranscriptListViewModel` becomes unused; delete the file. `TranscriptListViewModel.swift` exists only to drive the sidebar.

**`MainSelection`**: the `case transcript(String)` is removed. Detail-pane handler in `MainWindowView.detail` for `case .transcript` is removed.

**Detail-pane access to TranscriptDetailView**: the rich view is now reached only through a sheet, presented from inside `NoteSessionAutoSection`'s "Open transcript" button. Implementation:

- `NoteDetailView` gains a `@State private var openedTranscriptSession: Session?`.
- `NoteSessionAutoSection`'s `onOpenSession` callback (signature changes from `() -> Void` to `(Session) -> Void`) supplies the session to open.
- `NoteDetailView` presents `.sheet(item: $openedTranscriptSession)` → `TranscriptDetailView(session:)` wrapped in a `NavigationStack` so the user can dismiss with ⌘W or a Done button.

**Auto-create note title format**: when `AppDelegate.resolveNoteContext` auto-creates a note, the title format is unchanged ("Meeting on <medium-date short-time>"). When `TranscriptDetailViewModel.moveToNewNote` runs — gone, see below.

### 4. Dead code to remove from the prior Meeting-Notes work

These ship orphaned by this change and must be deleted:

- `Scribe/UI/TranscriptViewer/MoveToNotePicker.swift` — picker for an action that no longer exists.
- `TranscriptDetailViewModel.bindToNote`, `unbindFromNote`, `moveToNewNote` methods.
- `TranscriptDetailView` toolbar `Menu` for "Move to note" (the entire block).
- `showMoveToNoteSheet` @State in `TranscriptDetailView`.
- The "Move to new note" / "Existing note…" / "Open bound note" / "Unbind from note" menu items.

`TranscriptStore.bindSession(_:toNote:)` **stays**. It's used by `AppState.startSession(title:noteId:)` to attach the new session to the resolved note. (The new session is inserted by `createSession(title:)` then bound by `bindSession`; alternatively, `createSession` could take a noteId directly. We'll consolidate into the latter — see §2.)

Once `createSession(title:noteId:)` exists, `bindSession` is only used by tests. Keep it on the store as an internal API for tests but stop calling it from production. Mark its doc comment accordingly.

### 5. The "Open transcript" sheet

`TranscriptDetailView` is currently designed for navigation from a sidebar destination — it sits inside a `NavigationStack` provided by `MainWindowView.detail`. When presented as a sheet, it needs its own `NavigationStack` to expose the toolbar correctly.

```swift
.sheet(item: $openedTranscriptSession) { session in
    NavigationStack {
        TranscriptDetailView(session: session)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { openedTranscriptSession = nil }
                }
            }
    }
    .frame(minWidth: 720, minHeight: 540)
}
```

The Done button is added on the sheet wrapper, not inside `TranscriptDetailView`.

### 6. Notification cleanup

The `.scribeRequestNavigateToNote` notification (from slice 18.2) still applies — global Record auto-creates a note and posts it. The handler in `MainWindowView` still sets `selection = .note(id)`.

The `MainSelection.transcript(_:)` case can't appear in `selection` anymore. Audit `currentSelection` consumers for any `.transcript(_:)` switching code and remove.

## Files affected

| File | Change |
|---|---|
| `Scribe/Storage/DatabaseManager.swift` | Add migration `v11_session_noteId_backfill` |
| `Scribe/Storage/TranscriptStore.swift` | `createSession(title:)` becomes `createSession(title:noteId:)`. Doc on `bindSession` noting it's now test-only. |
| `Scribe/Storage/NoteStore.swift` | `deleteNote` does `DELETE FROM sessions WHERE noteId = ?` instead of sweep-to-NULL |
| `Scribe/App/AppState.swift` | `startSession(title:noteId:)` now passes `noteId` to `createSession` directly; no separate `bindSession` call |
| `Scribe/UI/MainWindow/MainWindowView.swift` | Remove `MainSelection.transcript(_:)`, the Transcripts sidebar section, the `transcriptsExpanded` state, the `viewModel: TranscriptListViewModel`, and the detail-pane case |
| **Delete** `Scribe/UI/TranscriptViewer/TranscriptListViewModel.swift` | Sole consumer (sidebar) is gone |
| **Delete** `Scribe/UI/TranscriptViewer/MoveToNotePicker.swift` | Orphan |
| `Scribe/UI/TranscriptViewer/TranscriptDetailView.swift` | Remove the Move-to-note Menu and `showMoveToNoteSheet` state |
| `Scribe/UI/TranscriptViewer/TranscriptDetailViewModel.swift` | Remove `bindToNote` / `unbindFromNote` / `moveToNewNote` |
| `Scribe/UI/Notes/NoteSessionAutoSection.swift` | `onOpenSession` callback shape changes to `(Session) -> Void` |
| `Scribe/UI/Notes/NoteDetailView.swift` | `@State openedTranscriptSession: Session?`, sheet wrapper, pass session into auto-section callback |
| `ScribeTests/SessionNoteIdMigrationTests.swift` | Add a backfill test (insert an orphan session into v10 schema state, then verify v11 migrated it) — or add to DatabaseIntegrationTests |
| `ScribeTests/TranscriptStoreNoteBindingTests.swift` | Update tests that call `createSession(title:)` to pass `noteId` |
| `ScribeTests/AppStateNoteBindingTests.swift` | Update tests that exercise the no-noteId path |
| `ScribeTests/DatabaseIntegrationTests.swift` | Update tests that call `createSession(title:)` |
| Any other test file calling `createSession(title:)` | Add `noteId` |

## Migration risk

- `eraseDatabaseOnSchemaChange = true` in DEBUG builds means devs lose their local DB on schema diff. Not new — pre-existing pattern. Document for the user before pulling.
- The backfill runs as part of `migrator.migrate` at app launch. For large numbers of orphan sessions, it executes in a single transaction — should be fast even for thousands of rows.

## Slicing

This isn't a multi-slice plan — the changes are tightly coupled (you can't remove `MainSelection.transcript` without first ensuring every existing session has a note, and you can't make `createSession` require `noteId` without updating callers). One PR.

Subdivision for execution order:

1. **Slice 20.1** — Migration v11 + the storage contract changes (createSession noteId required, deleteNote cascade). Tests updated for new signatures. **No UI change yet** — the sidebar still shows Transcripts.
2. **Slice 20.2** — Remove sidebar Transcripts section. Remove `MainSelection.transcript(_:)`. Add the sheet presentation. Delete orphan files.

Both slices can be one commit each; ship as one PR.

## Open question I'll commit on

**What if a user wanted to keep a transcript without a note?** They can't. The note acts as the container. If they want to disown a transcript, they delete the note — which deletes the transcript. There's no "transcript inbox" for unbound sessions because the design erases that concept.
