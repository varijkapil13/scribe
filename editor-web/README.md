# editor-web — Scribe CodeMirror 6 editor bundle

This tiny npm project builds the **self-contained, offline** JavaScript bundle
for Scribe's markdown editor (CodeMirror 6) that runs inside a `WKWebView` on
macOS (`WebMarkdownEditor.swift`).

The **build output is committed** to `../Scribe/Resources/Editor/` so the app
never needs node/npm at build or run time. This directory only matters when you
want to **rebuild** the bundle (upgrade CodeMirror, tweak the theme, etc.).

## Layout

- `src/editor.js` — the editor source: CodeMirror 6 `EditorView` with the
  markdown language, line wrapping, a prose theme (light/dark), and the
  JS↔native bridge.
- `package.json` — pins the CodeMirror packages and the esbuild build script.
- Output (committed, NOT here): `../Scribe/Resources/Editor/editor.bundle.js`
  plus the hand-written `index.html` and `editor.css` in that same folder.

## Rebuild

```sh
cd editor-web
npm install          # restores node_modules (gitignored)
npm run build        # esbuild -> ../Scribe/Resources/Editor/editor.bundle.js (IIFE, minified)
```

The build emits a single IIFE file (`--format=iife --global-name=ScribeEditor`,
`--target=safari16`). Commit the regenerated `editor.bundle.js`.

## Bridge contract

Mirrored in `Scribe/UI/Notes/WebMarkdownEditor.swift`:

- **JS → native** via `window.webkit.messageHandlers.scribe.postMessage(...)`:
  - `{type:"ready"}` once the editor mounts
  - `{type:"change", text}` debounced (200 ms) on every document edit
- **native → JS**:
  - `window.scribeSetDoc(text)` — replace the whole document (no change echo)
  - `window.scribeSetTheme("light"|"dark")` — swap the theme
  - `window.scribeFocus()` — focus the editor
