# Rich Editor — Phase 2 (Apple Notes-feel) Design

**Date:** 2026-05-15
**Status:** Approved

## Goal

Bring the note editor to feel comparable to Apple Notes' rich editor while keeping markdown as the canonical persistence format. Four user-visible additions: interactive checklists, sharper visual hierarchy, drag-drop image insertion, and rendered markdown tables. Inline diagram folding (mermaid / plantuml) is **untouched**.

## Non-goals (YAGNI)

- No switch to NSAttributedString / RTFD persistence. Body stays plain markdown so wiki-links, FTS, export, and portability keep working.
- No full table editor (cell-by-cell GUI). Tables stay markdown pipe syntax; only the rendering improves.
- No font picker, highlight colour, drawing tools, or iCloud-style collaboration. Out of model.
- No bullet-glyph substitution (`-` → `•`) — separate slice if we want it later; not Apple-Notes-defining.
- No new diagram rendering. Existing fold mechanism stays as-is.

## Design

### Slice A — Interactive checklists

**Markdown syntax** (canonical):
- `- [ ] task` — unchecked
- `- [x] task` — checked (lower-case `x`; we accept `X` on read, normalise to `x` on toggle)

**Rendering**: the formatter passes each line through a checklist matcher. When `^(\s*)- \[( |x|X)\] ` matches, replace the `- [ ]` / `- [x]` literal range with a single `NSTextAttachment` whose attachment cell draws a tappable circle or filled checkmark (24×24, accent colour on completed). The remaining text on the line gets a strikethrough + secondary colour when checked.

Reuse the existing `FoldRegistry` mapping so the markdown source ↔ formatted-attachment mapping is one mechanism, not two. The fold registry already tracks attachment-to-source-range pairs for diagrams.

**Click handling**: extend `MarkdownNSTextView.mouseDown` (currently handles diagram fold-expand and wiki-link nav) to detect clicks on checkbox attachments. On hit, locate the source range via FoldRegistry, mutate the markdown buffer (`[ ]` → `[x]` or vice versa), publish through the binding, and the formatter re-runs.

**Smart Enter / Tab**: extend `listPrefix(from:)` so:
- `- [ ] foo` → prefix is `- [ ] ` (with trailing space)
- `- [x] foo` → prefix is `- [ ] ` (continuation always starts a new unchecked item, matching Apple Notes)
- `- [ ] ` (empty item) + Enter → exits the list (existing empty-prefix-exit behaviour applies)
- Tab on a checklist line indents `  - [ ] ` (two spaces, matches existing list nesting)
- Backtab removes the leading two spaces

**Toolbar**: new `checklist` SF Symbol button + `⌘⇧U` shortcut (Apple Notes uses `⌘⇧U`). Inserts `- [ ] ` at the start of the current line (or wraps selected lines, like the existing bullet toggle).

**EditorActions** gains `var checklist: (() -> Void)?`.

**Files affected:**
- `Scribe/UI/DesignSystem/MarkdownEditorView.swift` — checklist matcher in `applyFormatting`, custom `ChecklistAttachmentCell`, `mouseDown` extension, `listPrefix` extension, `insertChecklist()` action handler.
- `Scribe/UI/Notes/FormatToolbar.swift` — new button.
- `Scribe/UI/DesignSystem/FoldRegistry.swift` — possibly extend to carry a "checklist" kind alongside "diagram" if range mapping needs to be aware of the kind. If today's `FoldRegistry` is kind-agnostic (just range pairs), no change needed.

**Tests:**
- `MarkdownNSTextViewListTests` (new) — `listPrefix` returns the right continuation for checklist lines.
- Manual smoke: type `- [ ] foo`, click the circle, verify it toggles to filled, text strikes through.

---

### Slice B — Visual hierarchy polish

Five small typography changes in `MarkdownFormatter` (inside `MarkdownEditorView.swift`).

| Element | Current | Target |
|---|---|---|
| First H1 in body (auto-title) | 22pt bold | 28pt semibold, 1.2× line height |
| Other H1 | 22pt bold | 22pt bold (unchanged) |
| H2 | 18pt semibold | 20pt semibold |
| H3 | 16pt semibold | 17pt semibold |
| Blockquote | italic, secondary colour | italic + secondary + **4pt accent bar drawn on the left** |
| Code block | monospace font | monospace + 1pt background fill (`surfaceSunken`) + 4pt rounded corners |

**Auto-title detection**: in the line-walk inside `applyFormatting`, track an `Bool` flag `seenFirstH1`. The first H1 line gets the auto-title style; subsequent H1s get the standard H1 style.

**Blockquote accent bar**: NSAttributedString paragraph styles don't draw a leading vertical bar natively. Use a custom `NSTextBlock`? Easier: subclass `MarkdownNSTextView` to override `drawBackground(in:)` for ranges with the existing `.blockquoteLine` attribute, drawing a 4pt-wide bar inset by the line's leading edge. We already have the attribute marker.

**Code block background fill**: same draw-backround override checking `.codeBlockLine` attribute.

**Files affected:**
- `Scribe/UI/DesignSystem/MarkdownEditorView.swift` — `MarkdownFormatter` heading sizes, `MarkdownNSTextView.drawBackground(in:)` override (or a `draw(_:in:)` override on the NSTextView).

**Tests:**
- No unit tests for visual sizes (would be brittle). Manual smoke: open a note with an H1, blockquote, and code block; visual hierarchy matches the target table.

---

### Slice C — Image drag-drop

**Storage layout**: `~/Library/Application Support/Scribe/attachments/<noteId>/<uuid>.<ext>`.

**Drop flow**:
1. `MarkdownNSTextView.registerForDraggedTypes([.fileURL, .png, .tiff])` in `awakeFromNib` (or `init`).
2. `prepareForDragOperation(_:)` — accept if at least one item is an image (UTType.image-conforming `.fileURL`, or `.png` / `.tiff` data).
3. `performDragOperation(_:)`:
   - Determine drop character index via `characterIndexForInsertion(at:)`.
   - Resolve image: file URL → original file; raw data → write to a temp PNG.
   - Compute destination: `attachments/<noteId>/<uuid>.<originalExt>`. Create parent directory if needed.
   - Copy the file (don't move) so dragging a Finder image doesn't relocate the user's file.
   - Insert markdown at the drop index: `![](attachments/<noteId>/<uuid>.<ext>)` (alt text empty — user can fill in).
   - The formatter re-runs and the image link gets folded into an `NSTextAttachment` showing the image.

**Inline rendering**: extend `MarkdownFormatter` to detect `!\[([^\]]*)\]\(([^)]+)\)`. When the URL resolves to a file under the attachments folder (relative path) or an absolute file URL, load via `NSImage(contentsOf:)`, scale to max 480px wide while preserving aspect, build an `NSTextAttachment` with an `NSTextAttachmentCell(imageCell:)`, and replace the markdown range with the attachment. Reuse `FoldRegistry` for source ↔ attachment mapping. Click-to-edit pattern matches diagrams.

**Note ID plumbing**: `MarkdownEditorView` gains a `var noteId: String? = nil` parameter, passed from `NoteEditorView` (which has the binding to the live note). The NSTextView holds the noteId for drop-target path construction. When `noteId` is nil (e.g. preview), drops are rejected.

**Cleanup on note delete**: `NoteStore.deleteNote` (currently cascades sessions) adds a step:
```swift
try? FileManager.default.removeItem(at: attachmentsDir(for: id))
```
Best-effort — if the directory doesn't exist or fails to remove, log and continue. Note rows are gone regardless.

**Files affected:**
- `Scribe/UI/DesignSystem/MarkdownEditorView.swift` — drag handlers, image attachment in formatter, noteId property.
- `Scribe/UI/Notes/NoteEditorView.swift` — pass `noteId` through.
- `Scribe/UI/Notes/NoteDetailView.swift` — pass `vm.note.id` into NoteEditorView (one-line edit).
- `Scribe/Storage/NoteStore.swift` — attachments folder cleanup on `deleteNote`.
- New helper module: `Scribe/Storage/AttachmentsDirectory.swift` — single struct that resolves paths under `~/Library/Application Support/Scribe/attachments/<noteId>/`, creates if missing, returns relative paths suitable for markdown.

**Tests:**
- `AttachmentsDirectoryTests` (new) — `directory(for: noteId)` creates parent if missing, returns a writable URL; `cleanup(for:)` removes the directory.
- `NoteStoreAttachmentsCleanupTests` (new) — after `deleteNote` of a note whose attachments folder exists, the folder is gone.
- Manual smoke for drop UX.

---

### Slice D — Markdown tables

**Detection**: in the line-walk inside `applyFormatting`, detect a contiguous block of:
1. Header row: line that matches `^\s*\|.+\|\s*$` (starts and ends with `|`, has ≥1 pipe in between).
2. Separator row: `^\s*\|[\s-:\|]+\|\s*$` immediately after the header.
3. Zero or more body rows matching the same pipe shape.

When found, treat the block as one rendered table.

**Rendering**: compute the max width of each column (in characters × monospace-equivalent point width, since we want grid alignment). Apply a custom `NSParagraphStyle` to each row's NSAttributedString with `tabStops` set so cells align to the column widths. Pad each cell to `width` chars with trailing spaces (in the formatter only — source markdown stays unpadded).

Per-cell visual style:
- Header row: semibold + thin underline (via `.underlineStyle`).
- Body rows: regular weight.
- Separator row (the `|---|---|` row): visually hidden (rendered as a horizontal rule line via background drawing OR a thin `NSTextAttachment` with an `NSDivider` cell). Source keeps the dashes so it's parseable.

**Tab navigation**: smart Tab inside a table row jumps the cursor to the start of the next cell (next `|` after current position on the same line). At the end of a row, Tab jumps to the first cell of the next row. Shift-Tab reverses.

**Insert-table toolbar action**: new `tablecells` SF Symbol button. Inserts at the cursor:
```
| Column 1 | Column 2 |
|----------|----------|
|          |          |
```

**EditorActions** gains `var insertTable: (() -> Void)?`.

**Files affected:**
- `Scribe/UI/DesignSystem/MarkdownEditorView.swift` — table matcher in formatter, tab stops application, smart Tab in `insertTab`, table insertion helper.
- `Scribe/UI/Notes/FormatToolbar.swift` — new button.

**Tests:**
- `MarkdownTableRendererTests` (new) — given a table source, the formatter returns an attributed string whose paragraph style has tab stops at the expected positions.
- Smart Tab unit tests if cleanly testable (NSTextView interaction is awkward).

---

## Slicing

Each slice ends with a green test run, a commit, and is independently shippable. Slice order matches user-perceived value:

1. **Slice A** — Checklists (the biggest "Apple Notes-feel" win).
2. **Slice B** — Visual hierarchy polish (improves *everything* including A's checklists).
3. **Slice C** — Image drag-drop.
4. **Slice D** — Markdown tables.

Each becomes its own PR off the same branch (or stacked PRs, user's call at finishing time).

## Migration risk

None. No DB schema changes. Markdown source is unchanged in shape — older notes render fine, new features are additive at the syntax level.

The attachments folder is created lazily on first drop, so existing installations don't need any migration.

## Risks

- **NSTextAttachment hit-testing for checkboxes**: the existing fold-expand click path is precedent; same pattern should work for checkboxes. Mouse-down handler needs to disambiguate checkbox-click from diagram-fold-expand. Both attachments live in `FoldRegistry`; add a kind tag so the click handler can route correctly.
- **`drawBackground(in:)` for blockquote/code background**: needs careful coord-space math against line fragments. May require an `NSLayoutManager` extension. If it proves invasive, fall back to a leading-character coloured bar inside the attributed string (uglier but simpler).
- **Auto-title detection**: tracking "first H1 seen yet" inside the line walk is straightforward. Risk is that the formatter currently runs per-edit (full pass on every change). Track the flag inside the single pass; no incremental state across passes.
- **Image scaling performance**: large images (4K+) scaled to 480px wide should be cached. First-render may stutter without caching. Mitigate with `NSImage.cacheMode = .always` and a `[URL: NSImage]` LRU cache in the formatter.
- **Table column-width math**: misaligns if user mixes proportional fonts inside a table. Mitigate by forcing the table block to monospace.

## Files summary

| File | Changes |
|---|---|
| `Scribe/UI/DesignSystem/MarkdownEditorView.swift` | Checklist attachment + matcher; heading-size table; auto-title; `drawBackground`; image drop handlers; image matcher + fold; table matcher + tab stops; smart Tab in table |
| `Scribe/UI/DesignSystem/FoldRegistry.swift` | Optional kind tag (`.diagram` / `.checklist` / `.image`) |
| `Scribe/UI/Notes/FormatToolbar.swift` | Checklist + Insert-table buttons |
| `Scribe/UI/Notes/NoteEditorView.swift` | Plumb `noteId` to MarkdownEditorView |
| `Scribe/UI/Notes/NoteDetailView.swift` | Pass `vm.note.id` into NoteEditorView (one line) |
| `Scribe/Storage/NoteStore.swift` | Cleanup attachments folder on `deleteNote` |
| **New** `Scribe/Storage/AttachmentsDirectory.swift` | Resolve / create / clean up attachment paths |
| **New** `ScribeTests/MarkdownNSTextViewListTests.swift` | `listPrefix` for checklist lines |
| **New** `ScribeTests/AttachmentsDirectoryTests.swift` | Path resolution + cleanup |
| **New** `ScribeTests/NoteStoreAttachmentsCleanupTests.swift` | Note delete removes attachments folder |
| **New** `ScribeTests/MarkdownTableRendererTests.swift` | Table tab-stop computation |

## Open question I'll commit on

**Should checkbox toggles be debounced or write immediately?** Apple Notes writes immediately. We follow suit — every click is a synchronous mutation through the binding. The autosave debounce on `NoteDetailViewModel` (1.5s, existing) batches the write to disk so we don't fsync per click.
