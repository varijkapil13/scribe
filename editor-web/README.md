# editor-web — Scribe CodeMirror 6 editor bundle

This tiny npm project builds the **self-contained, offline** JavaScript bundle
for Scribe's markdown editor (CodeMirror 6) that runs inside a `WKWebView` on
macOS (`WebMarkdownEditor.swift`).

The **build output is committed** to `../Scribe/Resources/Editor/` so the app
never needs node/npm at build or run time. This directory only matters when you
want to **rebuild** the bundle (upgrade CodeMirror, tweak the theme, etc.).

## Layout

- `src/editor.js` — the editor source: CodeMirror 6 `EditorView` with the
  markdown language, line wrapping, a prose theme (light/dark), Obsidian-style
  **live preview** (syntax-tree decorations that render headings / emphasis /
  lists / task checkboxes / blockquotes and hide markers off the active line),
  plus **wiki-links** `[[Title]]` / `[[Title|alias]]`, an in-web **slash command
  menu**, **KaTeX math** (`$…$` / `$$…$$`), fenced **mermaid** + **plantuml**
  diagram rendering, and the JS↔native bridge.
- `src/diagrams.js` — mermaid (offline) + plantuml (encoded URL via
  `https://www.plantuml.com/plantuml/svg/…`) rendering, cached by source hash.
- `src/katex-css.js` — injects KaTeX's stylesheet (imported as text; fonts
  inlined as data URLs) so math renders fully offline.
- `build.mjs` — esbuild build (CSS-as-text + font data-URL loaders).
- `package.json` — pins the CodeMirror / mermaid / katex packages + build script.
- Output (committed, NOT here): `../Scribe/Resources/Editor/editor.bundle.js`
  plus the hand-written `index.html` and `editor.css` in that same folder.

## Rebuild

```sh
cd editor-web
npm install          # restores node_modules (gitignored)
npm run build        # node build.mjs -> ../Scribe/Resources/Editor/editor.bundle.js
```

The build emits a single self-contained IIFE file (`format: iife`,
`globalName: ScribeEditor`, `target: safari16`, minified). KaTeX fonts are
inlined as data URLs and mermaid is bundled inline, so the only runtime network
use is the PlantUML image fetch (matching the prior native implementation).
Commit the regenerated `editor.bundle.js`.

### Bundle size

The bundle is **~3.6 MB** (was ~496 KB before mermaid + KaTeX). The bulk is
mermaid's diagram engines (cytoscape, sequence/etc. ~1.6 MB) and KaTeX's JS +
inlined woff2 fonts (~0.6 MB). This ships once inside the app bundle and is
loaded from `file://` (no network), so the size is a one-time on-disk cost, not
a per-load download.

## Bridge contract

Mirrored in `Scribe/UI/Notes/WebMarkdownEditor.swift`:

- **JS → native** via `window.webkit.messageHandlers.scribe.postMessage(...)`:
  - `{type:"ready"}` once the editor mounts
  - `{type:"change", text}` debounced (200 ms) on every document edit
  - `{type:"wikilink", target}` when the user clicks a `[[wiki link]]` (the
    `target` is the lookup title, i.e. the text before any `|alias`)
- **native → JS**:
  - `window.scribeSetDoc(text)` — replace the whole document (no change echo)
  - `window.scribeSetTheme("light"|"dark")` — swap the theme
  - `window.scribeSetFontSize(px)` — set the body prose font size (points)
  - `window.scribeSetKnownTitles([title, …])` — known note titles, so wiki-links
    can be styled resolved vs broken (matched case-insensitively)
  - `window.scribeFocus()` — focus the editor
