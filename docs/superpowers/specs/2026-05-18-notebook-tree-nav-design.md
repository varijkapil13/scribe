# Notebook Subfolder + Confluence-style Sidebar — Design

**Date:** 2026-05-18  
**Status:** Approved → implementing

---

## Goal

Add hierarchical subfolder support to Notebooks and replace the flat sidebar notebook list with a Confluence-style recursive tree. Each folder can hold notes AND sub-folders at the same level.

## Chosen approach: C1

- Single sidebar (no icon rail, no extra column).
- App nav at top (Live, Tasks, Today, Notes/Inbox/All).
- Notebooks section shows a recursive `DisclosureGroup` tree.
- Notes appear as leaves inside their notebook node.
- Clicking a note → `MainSelection.note(id)` → full-width `NoteDetailView`.
- Clicking a folder expands/collapses it.

---

## Schema

```sql
-- migration v12_notebook_parentId
ALTER TABLE notebooks ADD COLUMN parentId TEXT REFERENCES notebooks(id) ON DELETE SET NULL;
```

`Notebook.parentId: String?` — nil = top-level.

---

## NoteStore additions

| Method | Change |
|---|---|
| `createNotebook(name:parentId:)` | parentId param added (default nil) |
| `observeAllNotes()` | New — mirrors `observeNotebooks()` for sidebar leaves |
| `deleteNotebook(id:)` | Also nulls out child notebooks' parentId |

---

## New view: `NotebookTreeView` (`Scribe/UI/Notes/NotebookTreeView.swift`)

Recursive structure:

```
NotebookTreeView(parentId: nil, notebooks: [...], notes: [...], selection: $sel)
└── per child notebook:
    NotebookTreeRow (DisclosureGroup)
    ├── NotebookTreeView(parentId: nb.id, ...)   ← sub-folders
    └── NoteLeafRow per note where note.notebookId == nb.id
```

Expansion state: `@AppStorage("expandedNotebookIds") Set<String>`.

Context menus:
- Folder: New Note Here, New Subfolder, Rename, Delete
- Leaf: Open, Move to…, Delete

---

## MainWindowView changes

- Remove: flat `notebooks` state, `isCreatingNotebook`, `notebookDraftName`, `renamingNotebookId`, `inlineRenameName`.
- Add: `@State private var allNotes: [Note]`, `.onReceive(NoteStore.shared.observeAllNotes()...)`.
- Replace notebooks `Section` body with `NotebookTreeView(parentId: nil, ...)`.
- Top-level "+" button creates a top-level notebook (parentId: nil).
