// esbuild build for the Scribe editor bundle.
//
// Produces a single self-contained IIFE (global `ScribeEditor`) at
// ../Scribe/Resources/Editor/editor.bundle.js. KaTeX's stylesheet is imported
// as TEXT and injected at runtime; its woff2/woff/ttf fonts are inlined as data
// URLs so math renders fully offline with no sidecar font files. Mermaid is
// bundled inline (dynamic imports are resolved into the single file since IIFE
// output cannot be code-split).

import { build } from "esbuild";

await build({
  entryPoints: ["src/editor.js"],
  bundle: true,
  format: "iife",
  globalName: "ScribeEditor",
  outfile: "../Scribe/Resources/Editor/editor.bundle.js",
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

console.log("built ../Scribe/Resources/Editor/editor.bundle.js");
