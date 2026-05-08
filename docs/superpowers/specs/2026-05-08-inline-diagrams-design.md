# Inline Diagram Rendering — Design

**Date:** 2026-05-08
**Status:** Draft
**Supersedes:** Section 4 ("Diagram Side Panel") of `2026-05-08-rich-editor-design.md`, plus the bottom-panel iteration shipped in 187262d.

## Goal

Replace the bottom diagram panel with **inline rendering**: each fenced ` ```mermaid ` / ` ```plantuml ` block is shown as a rendered preview in place of its source while the cursor is outside it. When the cursor enters (or the user clicks the on-hover **Edit** button), the block expands back to editable source. Saved markdown is unchanged.

## Non-goals

- Side-by-side rendering, fullscreen preview, or zoom.
- Inline error badges. Failed renders fall back to plain source — no extra UI.
- Other code-fence languages (only `mermaid` and `plantuml` are folded).
- Editing the rendered SVG directly (e.g., dragging nodes).

## Design

### 1. Display ≠ source via attribute-tagged attachments

The fundamental architecture change: `NSTextStorage` no longer mirrors the markdown source character-for-character. It holds the **display** form, which may substitute fence ranges with attachments. The source is reconstructed from storage on demand.

Two new `NSAttributedString.Key`s:

```swift
extension NSAttributedString.Key {
    static let foldSource = NSAttributedString.Key("scribe.foldSource") // String — original fence source incl. ```fence``` markers
    static let foldId     = NSAttributedString.Key("scribe.foldId")     // UUID — links attachment to renderer cache entry
}
```

For each fence the formatter chooses to fold, it emits one `U+FFFC` attachment character carrying:

- `.attachment` → `NSTextAttachment` whose `image` is the rendered `NSImage`
- `.foldSource` → the full fence text (e.g., `` "```mermaid\ngraph TD\n  A --> B\n```" ``)
- `.foldId` → a UUID used by the hover overlay to look up which fence to expand

**Reconstruction (`storage → source string`):** walk runs; for each run with `.foldSource`, append that string; for plain runs, append the substring. This produces the markdown source. Implemented as `MarkdownNSTextView.markdownSource: String { get }`.

The `MarkdownEditorView.text` binding is set from this getter — never from `tv.string` directly.

---

### 2. Fold lifecycle

**Trigger:** `Coordinator.applyFormatting` runs after every text change AND every selection change. It is the single entry point that decides what to fold.

**Decision per fence (in source coords):**

| Selection state | Render cached? | Result |
|---|---|---|
| Selection intersects fence range | — | Plain source (expanded) |
| No intersection | yes | Folded — single attachment |
| No intersection | no, render in flight | Plain source; re-format scheduled when render arrives |
| No intersection | render failed | Plain source (no badge) |

**Selection intersection rule:** a fence is "expanded" if `selection.location ≥ fenceStart` AND `selection.location ≤ fenceEnd` (inclusive on both ends, so cursor sitting on the boundary line counts). For non-zero-length selections, expand the fence if `selection ∩ fenceRange ≠ ∅`.

**Click-to-edit on the rendered preview:** handled via the on-hover Edit button (Section 4), not by clicking the attachment glyph itself. Clicking the attachment glyph behaves like a normal NSTextView click — places the cursor adjacent to it (which, by definition, is outside the fence range, so the fold stays).

**Preventing format-loop on selection change:** `applyFormatting` already runs on text change. We add a `textViewDidChangeSelection` delegate. To avoid recursion when `applyFormatting` itself sets selection (e.g., after expanding a fold), guard with a `Coordinator.isApplyingFormatting: Bool` flag.

---

### 3. Async rendering & cache

`DiagramRenderer` is refactored from "drives a WKWebView panel" to "produces NSImages on demand."

**API:**

```swift
@MainActor
final class DiagramRenderer {
    static let shared = DiagramRenderer()

    /// Returns cached image immediately if available; otherwise nil and triggers async render.
    /// The completion fires on the main actor when the render arrives.
    func image(type: DiagramType, source: String, onReady: @escaping () -> Void) -> NSImage?
}
```

- Cache key: `"\(type):\(SHA256(source))"` → `NSImage`.
- Cache is unbounded (typical note has a few diagrams).
- A separate `inFlight: Set<String>` prevents duplicate renders for the same key.
- On render completion, the cached image is stored AND every queued `onReady` callback for that key fires — which causes `applyFormatting` to re-run, picking up the now-cached image and folding the fence.

**Mermaid rendering:**
- `DiagramRenderer` lazily creates one hidden `WKWebView` (off-screen, no superview required — held by the singleton) loading the existing `diagram-renderer.html`.
- Rendering: `evaluateJavaScript("renderMermaid(<jsonString>)")` returns `{ok, svg}` JSON exactly as today.
- SVG string → `Data` → `NSImage(data:)`. NSImage handles SVG natively on macOS 14+; current target (Darwin 25 ≈ macOS 16) is well above that.
- **Bootstrapping:** if the WKWebView hasn't finished loading when the first render request arrives, the request waits in a queue drained on `webView(_:didFinish:)`.

**PlantUML rendering:**
- Same `URLSession` GET to `plantuml.com/plantuml/svg/<encoded>` as today.
- SVG bytes → `NSImage(data:)`. No HTML wrapper needed.

**Image sizing:** the SVG defines its natural size. `NSTextAttachment.bounds` is set to width `min(naturalWidth, editorContentWidth - 32pt)`; height scaled to preserve aspect ratio. Editor content width = `tv.bounds.width − tv.textContainerInset.width × 2`. Recomputed on every `applyFormatting` so the preview reflows on window resize (resize hook in Section 6 below).

---

### 4. Hover Edit button

A small chrome overlay appears over a folded preview on hover. Clicking it expands the fold by moving the cursor into the fence's source range.

**Implementation:**

A single reusable `NSView` subview of `MarkdownNSTextView` named `EditButtonOverlay` — one instance, repositioned. Hidden by default.

- `MarkdownNSTextView` owns one `NSTrackingArea` covering the visible rect with options `[.activeInKeyWindow, .mouseMoved, .inVisibleRect]`. Re-installed in `updateTrackingAreas` (standard pattern).
- On `mouseMoved`: hit-test the character index at the cursor location. If that character has a `.foldId` attribute, get its bounding rect via `layoutManager.boundingRect(forGlyphRange:in:)` and position the overlay at the rect's top-right with an 8pt inset. Store the active `foldId`. If the character has no `.foldId`, hide the overlay.
- The overlay is an `NSButton` styled with `pencil` SF Symbol, semi-transparent background (`NSColor.controlBackgroundColor.withAlphaComponent(0.85)`), 4pt corner radius, 24×24pt.
- Button click action: look up the fence whose `.foldId` matches the active foldId (via attribute scan), set `tv.selectedRange = NSRange(location: foldEndInDisplay, length: 0)` — but we need source-coord tracking, see below.

**The "where is this fold's source range" question:** at any point in time, `Coordinator.foldRegistry: [UUID: FoldEntry]` maps `foldId → (sourceRange, displayLocation)`. Rebuilt by `applyFormatting` after every storage edit. The Edit button consults this registry to find where to place the cursor.

`displayLocation` is the location of the attachment char in display coords; in source coords this is `sourceRange.location` — the very first character of the fence (the opening backtick of ` ```mermaid `). Setting `tv.selectedRange = NSRange(location: displayLocation, length: 0)` therefore expands the fence and lands the cursor at fence start. To put the cursor in the diagram body instead, we set the source-coord target to `sourceRange.location + bodyOffset`, where `bodyOffset` is the index immediately after the opening fence line (computed via `source.firstNewline + 1`). Mapped through `displayLocation(forSource:)` *before* reformat, then re-applied after reformat — same flow as Section 5's selection round-trip.

---

### 5. Edit handling

The single non-trivial concern is making sure edits at fold boundaries correctly mutate the source.

**`textDidChange` flow:**
1. `tv.string` may now contain `U+FFFC` attachment characters; we don't read it directly.
2. Read `tv.markdownSource` (Section 1) → this is the new source.
3. Set `parent.text = newSource`.
4. Call `applyFormatting(to: tv)` — this rebuilds storage from `newSource`, deciding which fences to fold based on the current selection.
5. After rebuild, restore selection: map the pre-edit cursor's source-coord to the new display-coord using the new `foldRegistry`.

**Why this works without coordinate-mapping interceptors:**
- A normal edit in plain (non-folded) text updates the plain run; reconstruction yields the expected source.
- Backspace immediately after a folded attachment: NSTextView deletes the attachment char. Reconstruction yields source minus that fence's source. ✓
- Typing immediately after a folded attachment: NSTextView inserts new chars after the attachment. Reconstruction yields source with the new chars after the fence. ✓
- Selection across a folded attachment + delete: NSTextView removes that range. Reconstruction yields source minus the fence(s) plus surrounding deleted chars. ✓
- Paste: same — pasted chars are inserted in display, then `markdownSource` reconstructs source.

**Selection tracking across reformat:**
Before `applyFormatting`, capture the pre-edit selection in source coords using the *previous* `foldRegistry`. After reformat, map back to display coords using the new registry. Helper functions:

```swift
func sourceLocation(forDisplay loc: Int, registry: [FoldEntry]) -> Int
func displayLocation(forSource loc: Int, registry: [FoldEntry]) -> Int
```

Both walk the registry (small, ~unit count) summing the size delta `sourceLength - 1` for each fold whose displayLocation precedes `loc`.

The existing code in `applyFormatting` saves/restores `tv.selectedRanges` directly; we replace that with source-coord-mediated round-trip.

---

### 6. Removing the bottom panel

- `NoteDetailView.swift`:
  - Delete the `@State private var showDiagramPanel: Bool` line.
  - Delete the toolbar `Button` that toggles the panel.
  - Delete the `DiagramPanelBar` view in the body and the private struct definition.
  - The `bodyPublisher` is no longer needed — delete it. (The renderer is invoked synchronously per fence.)
- `DiagramPreviewPanel.swift`: deleted.
- `DiagramRenderer.swift`: refactored as in Section 3. The `bind(bodyPublisher:webView:)` API is removed; `extractBlocks(from:)` stays (used by both formatter and tests).

The toolbar button to toggle the panel goes away; there is no replacement. Folds are always-on.

---

## File summary

| File | Change |
|---|---|
| `Scribe/UI/DesignSystem/MarkdownEditorView.swift` | Add fold logic to `applyFormatting`; add `markdownSource` getter, `foldRegistry`, `EditButtonOverlay`, `NSTrackingArea`, selection-change handler. Substantial. |
| `Scribe/UI/Notes/DiagramRenderer.swift` | Rewrite as image producer + cache + headless WKWebView. Keep `extractBlocks`. |
| `Scribe/UI/Notes/DiagramPreviewPanel.swift` | **Delete.** |
| `Scribe/UI/Notes/NoteDetailView.swift` | Remove `showDiagramPanel`, toolbar button, `DiagramPanelBar`, `bodyPublisher`. |
| `ScribeTests/DiagramRendererTests.swift` | Adjust to new API. `extractBlocks` cases unchanged. Add cache-hit/miss test. |

No new Swift dependencies. `beautiful-mermaid.js` and `diagram-renderer.html` resources stay (now used by the headless renderer).

---

## Edge cases

- **Empty fence body** (` ```mermaid\n``` `) — Mermaid render fails → no fold, source visible.
- **Unclosed fence** — `extractBlocks` already requires a closing ```; never folded.
- **Two fences, cursor in second** — first folds, second expanded.
- **Window resize while folded** — `MarkdownNSTextView.setFrameSize` already runs on every resize and recomputes `textContainerInset`. We extend that override: track the last-seen content width; when it changes, post a coalesced (`DispatchQueue.main.async`, deduped via a flag) call to `Coordinator.applyFormatting` so attachment bounds re-scale.
- **Note switch / editor reload** — fresh `Coordinator`, fresh `foldRegistry`, cache is process-global so unchanged sources render instantly.
- **External `text` binding update** (e.g., load from disk) — `updateNSView` calls `applyFormatting`, which folds if cache hits; otherwise async render kicks in.
- **Source contains `U+FFFC`** — extremely rare; we use `.foldSource` attribute presence as the discriminator, not the character itself, so spurious U+FFFCs in source are reconstructed as themselves (no fold attribute → kept verbatim).
- **Render takes longer than user keystrokes** — render keyed by `(type, source)`; if user keeps editing, the source hash changes and old in-flight renders become stale. Stale results still write to cache (cheap) but nothing references that key, so they're harmless.
- **Dark mode toggle while app is open** — Mermaid SVG bakes in the appearance at render time. v1 behavior: appearance at first-render sticks until the note is reloaded. Re-rendering on `NSApp.effectiveAppearance` change is deferred to Phase 2 and listed in "Out of scope" below.

---

## Test strategy

- **Unit (pure):** `MarkdownNSTextView.markdownSource` reconstruction with mocked attribute-tagged storage; `sourceLocation`/`displayLocation` mapping helpers.
- **Unit (renderer):** `DiagramRenderer` cache hit/miss; in-flight dedup; SVG → `NSImage` smoke test using a static SVG fixture.
- **Integration (manual, documented):** open a note with three fences, verify all three render after debounce; click into one with arrow keys → that one expands; type → still expanded; arrow out → re-folds; hover → Edit button appears; click Edit → expanded; backspace immediately after a folded preview → entire fence deleted; switch to a Plant­UML fence offline → source remains visible.

---

## Out of scope (Phase 2+)

- Inline error badge with retry on failed render.
- Rendering on `prefers-color-scheme` change without app restart.
- Editing/repositioning rendered SVG nodes.
- Folding non-diagram fences (`swift`, `js`, etc.) into syntax-highlighted previews.
