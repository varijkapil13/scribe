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
- `src/diagrams.js` — mermaid (offline, **lazy-loaded** via dynamic import on
  first mermaid render) + plantuml (encoded URL via
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

The build emits an **ESM module** entry (`format: esm`, `splitting: true`,
`target: safari16`, minified) loaded by `index.html` as
`<script type="module" src="editor.bundle.js">`, plus code-split chunks under
`chunks/`. The heavy deps — **mermaid** (~1.6 MB) and **KaTeX** (~0.6 MB) — are
**lazy-loaded** via dynamic `import()` only when a mermaid/plantuml or math node
actually renders, so the editor paints instantly instead of blocking on those
modules. KaTeX fonts are still inlined as data URLs. Every emitted chunk is
self-contained local JS (no CDN), shipped inside `Scribe/Resources/Editor/` and
loaded over `file://`, so the only runtime network use is the PlantUML image
fetch (matching the prior native implementation). Output filenames are
deterministic (no entry hash; chunks use a content hash for uniqueness). Commit
the regenerated `editor.bundle.js` **and** the `chunks/` directory.

### Bundle size

The primary `editor.bundle.js` is **~0.5 MB** (down from ~3.6 MB when mermaid +
KaTeX were bundled eagerly). The mermaid diagram engines and KaTeX (JS +
inlined woff2 fonts) now live in separate `chunks/*.js` files (~3.1 MB total)
that load lazily on first use. Everything ships once inside the app bundle and
loads from `file://` (no network), so the on-disk total is unchanged — but cold
editor paint no longer pays the mermaid/KaTeX parse cost.

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
