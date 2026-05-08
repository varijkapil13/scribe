# Rich Editor — Phase 1 Design

**Date:** 2026-05-08  
**Status:** Approved

## Goal

Upgrade Scribe's note editor from a basic markdown text view to a writing experience comparable to Bear/Obsidian. Phase 1 covers typography, a formatting toolbar, keyboard shortcuts, and a diagram preview panel.

## Scope

Phase 1 only. Later phases (rich blocks, editing ergonomics, tags) are out of scope here.

## Design

### 1. Typography & Layout

**What changes:** `MarkdownFormatter.base()` gains a paragraph style; `MarkdownEditorView.updateNSView` computes dynamic insets.

| Property | Current | Target |
|---|---|---|
| Base font size | ~13pt (system default) | 15pt |
| Line height | ~1.2× | 1.7× (`lineHeightMultiple`) |
| Paragraph spacing | 0 | 8pt (`paragraphSpacing`) |
| Max content width | full window width | 640px, centered |

Max width implementation: `textContainerInset.width = max(16, (viewWidth - 640) / 2)`. Recalculated in `updateNSView` on every layout pass. Content stays centered as the window grows.

`NoteDetailView` currently applies `.padding(.horizontal, DesignTokens.Spacing.xxxl)` to `NoteEditorView` — this must be **removed** so the `NSTextView`'s dynamic inset is the sole source of horizontal centering. The title/metadata header keeps its own padding.

**Files:** `MarkdownEditorView.swift` (same file as `MarkdownFormatter`).

---

### 2. Format Toolbar

Fixed `HStack` strip pinned above the editor scroll view inside `NoteEditorView`.

**Buttons:**
- **B** — bold (`**…**`)
- *I* — italic (`*…*`)
- ~~S~~ — strikethrough (`~~…~~`)
- `` `code` `` — inline code (`` `…` ``)
- Separator
- Paragraph picker — dropdown: Paragraph / H1 / H2 / H3 (adds/removes `#` prefix on current line)

**SwiftUI ↔ AppKit bridge via `EditorActions`:**

```swift
@Observable final class EditorActions {
    var bold: (() -> Void)?
    var italic: (() -> Void)?
    var strikethrough: (() -> Void)?
    var code: (() -> Void)?
    var setHeading: ((Int) -> Void)?   // 0 = paragraph, 1–3 = H1–H3
}
```

`MarkdownEditorView.makeNSView` assigns closures that call into the live `NSTextView`. `FormatToolbar` holds a reference to the same `EditorActions` instance and calls closures on button tap.

`EditorActions` is created in `NoteEditorView`, passed into both `FormatToolbar` and `MarkdownEditorView`.

**Files:** new `FormatToolbar.swift`; `NoteEditorView.swift`; `MarkdownEditorView.swift`.

---

### 3. Keyboard Shortcuts

Override `performKeyEquivalent` in `MarkdownNSTextView`:

| Shortcut | Action |
|---|---|
| ⌘B | wrap/unwrap selection in `**…**` |
| ⌘I | wrap/unwrap selection in `*…*` |
| ⌘` | wrap/unwrap selection in `` `…` `` |
| ⌘K | if URL in clipboard → `[selection](url)`; else → insert `[[` to trigger wiki-link |

**Toggle behaviour:** `applyInlineFormat(_ marker: String)` checks if selected text is already wrapped in `marker`; if yes, strips markers; if no, wraps. Handles empty selection (inserts markers and positions cursor between them).

**Files:** `MarkdownEditorView.swift` (`MarkdownNSTextView` subclass).

---

### 4. Diagram Side Panel

When the note body contains at least one fenced diagram block (` ```mermaid ` or ` ```plantuml `), a preview panel is available to the right of the editor.

**Layout:** `NoteDetailView` is a `VStack` (header / editor / backlinks). Only the editor row is replaced with an `HSplitView` containing the editor on the left and the diagram panel on the right. Header and backlinks are unaffected. Panel hidden by default; a toggle button in the note toolbar shows/hides it. Panel minimum width: 300px.

**Update cycle:** `DiagramRenderer` subscribes to note body changes via a 500ms debounce. On trigger, parses all fenced blocks, renders each, and updates the panel.

**Mermaid rendering (`beautiful-mermaid`):**
- Bundle the built JS distribution of [`beautiful-mermaid`](https://github.com/lukilabs/beautiful-mermaid) as an app resource (`Resources/beautiful-mermaid.js`)
- `DiagramPreviewPanel` loads a minimal local HTML page into `WKWebView` that imports the bundled script
- Per diagram: call `render(source)` via `WKWebView.evaluateJavaScript(_:completionHandler:)` (async bridge, but `beautiful-mermaid`'s JS render is synchronous so the result arrives in a single callback); receive SVG string; inject into panel
- Fully offline. Theme (`light`/`dark`) passed based on `NSApp.effectiveAppearance`

**PlantUML rendering:**
- `PlantUMLEncoder.swift` implements PlantUML's text encoding algorithm in pure Swift (deflate → base64 variant → encode to PlantUML alphabet)
- Encoded string appended to `https://www.plantuml.com/plantuml/svg/`
- SVG fetched via `URLSession`, injected into panel alongside Mermaid diagrams
- Requires internet. Network errors shown inline with a retry button.

**Parsing:** `DiagramRenderer.extractBlocks(_ body: String) -> [(type: DiagramType, source: String)]` — regex over fenced code blocks, returns ordered list preserving document order.

**Files:** new `DiagramPreviewPanel.swift`, `DiagramRenderer.swift`, `PlantUMLEncoder.swift`; modified `NoteDetailView.swift`.

---

## File Summary

| File | Change |
|---|---|
| `MarkdownEditorView.swift` | dynamic inset, `EditorActions` setup, `performKeyEquivalent`, `applyInlineFormat` |
| `NoteEditorView.swift` | add `FormatToolbar` above editor, own `EditorActions` instance |
| `NoteDetailView.swift` | wrap in `HSplitView`, diagram panel toggle button |
| **New** `FormatToolbar.swift` | SwiftUI toolbar view |
| **New** `DiagramPreviewPanel.swift` | `WKWebView`-based panel |
| **New** `DiagramRenderer.swift` | parse blocks, drive rendering, 500ms debounce |
| **New** `PlantUMLEncoder.swift` | PlantUML text encoding in Swift |

**No new Swift package dependencies.** `beautiful-mermaid` bundled as a JS resource file.

---

## Out of Scope (Phase 2+)

- Interactive checkboxes / task blocks
- Code fences with syntax highlighting
- Tables
- Inline `#tag` highlighting and autocomplete
- Slash commands
- Smart list continuation (Tab to indent)
