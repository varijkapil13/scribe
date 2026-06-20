// esbuild build for the Scribe editor bundle.
//
// Produces an ESM primary entry at ../Scribe/Resources/Editor/editor.bundle.js
// plus code-split chunks for the LAZY-LOADED heavy deps (mermaid ~1.6 MB and
// KaTeX ~0.6 MB). Those deps are pulled in via dynamic `import()` only when a
// mermaid/plantuml or math node actually renders, so the editor paints
// instantly. esbuild dynamic-import code-splitting requires format:"esm" +
// splitting:true with an `outdir` (no single `outfile`).
//
// KaTeX's stylesheet is imported as TEXT and injected at runtime; its
// woff2/woff/ttf fonts are inlined as data URLs so math renders fully offline
// with no sidecar font files. All emitted chunks are self-contained local JS
// (no CDN URLs); they ship inside Scribe/Resources/Editor/ and load over
// file:// (WKWebView has read access to that folder), so the only runtime
// network use remains the PlantUML image fetch.
//
// Output filenames are deterministic (no content hashes) so the committed file
// set is predictable: editor.bundle.js + chunks/*.js.

import { build } from "esbuild";

await build({
  entryPoints: { "editor.bundle": "src/editor.js" },
  bundle: true,
  format: "esm",
  splitting: true,
  outdir: "../Scribe/Resources/Editor",
  entryNames: "[name]",
  // Shared/dynamic chunks. The content hash makes names unique (multiple
  // distinct chunks can't share one name) while staying deterministic across
  // rebuilds for identical content — so the committed file set is stable.
  chunkNames: "chunks/[name]-[hash]",
  minify: true,
  target: "safari16",
  legalComments: "none",
  loader: {
    // KaTeX CSS imported as a JS string (injected into <style> at runtime).
    ".css": "text",
    // Inline KaTeX fonts so the bundle is offline-self-contained.
    ".woff2": "dataurl",
    ".woff": "dataurl",
    ".ttf": "dataurl",
  },
});

console.log("built ../Scribe/Resources/Editor/editor.bundle.js (+ chunks/)");
