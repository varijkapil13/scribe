// Scribe CodeMirror 6 markdown editor — bundled for the macOS WKWebView host.
//
// This file is bundled (esbuild, IIFE, global name `ScribeEditor`) into
// ../Scribe/Resources/Editor/editor.bundle.js. The committed bundle is what the
// app ships; node is only needed to (re)build it, never at app build/run time.
//
// Native bridge contract:
//   JS -> native:  window.webkit.messageHandlers.scribe.postMessage({type, ...})
//                  - {type:"ready"}            once the editor is mounted
//                  - {type:"change", text}     debounced, on every doc edit
//   native -> JS:  window.scribeSetDoc(text)   replace the whole document
//                  window.scribeSetTheme("light"|"dark")

import { EditorView, keymap } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import {
  syntaxHighlighting,
  defaultHighlightStyle,
  HighlightStyle,
} from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { tags as t } from "@lezer/highlight";

// ── Native bridge helpers ────────────────────────────────────────────────
function postToNative(message) {
  try {
    window.webkit.messageHandlers.scribe.postMessage(message);
  } catch (e) {
    // Running outside the WKWebView host (e.g. a plain browser for previews).
    // Swallow — the editor still works, it just has no native peer.
  }
}

// Debounce so we don't flood the native side on every keystroke.
let changeTimer = null;
function scheduleChange(text) {
  if (changeTimer !== null) clearTimeout(changeTimer);
  changeTimer = setTimeout(() => {
    changeTimer = null;
    postToNative({ type: "change", text });
  }, 200);
}

// ── Theming ────────────────────────────────────────────────────────────────
// Driven from native via scribeSetTheme. We swap the theme + highlight style
// through a Compartment so reconfiguration is cheap and non-destructive.
const themeCompartment = new Compartment();
const highlightCompartment = new Compartment();

// Shared prose layout (font, width, spacing) — NOT a code editor look.
const proseBase = EditorView.theme({
  "&": {
    height: "100%",
    fontSize: "17px",
  },
  ".cm-scroller": {
    fontFamily:
      '-apple-system, "SF Pro Text", "Helvetica Neue", "Segoe UI", system-ui, sans-serif',
    lineHeight: "1.7",
    overflow: "auto",
  },
  // Center a readable column with generous padding (Obsidian / Bear feel).
  ".cm-content": {
    maxWidth: "44rem",
    margin: "0 auto",
    padding: "2.5rem 1.75rem 6rem",
    caretColor: "var(--scribe-caret)",
  },
  ".cm-line": {
    padding: "0",
  },
  // No code-editor gutter / line numbers.
  ".cm-gutters": { display: "none" },
  "&.cm-focused": { outline: "none" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--scribe-caret)" },
});

function makeTheme(dark) {
  return EditorView.theme(
    {
      "&": {
        color: dark ? "#e6e6e6" : "#1d1d1f",
        backgroundColor: dark ? "#1e1e1e" : "#ffffff",
        "--scribe-caret": dark ? "#e6e6e6" : "#1d1d1f",
      },
      ".cm-selectionBackground, ::selection": {
        backgroundColor: dark ? "#3a4a63" : "#b9d4f9",
      },
      "&.cm-focused .cm-selectionBackground, &.cm-focused ::selection": {
        backgroundColor: dark ? "#3a4a63" : "#b9d4f9",
      },
      ".cm-activeLine": { backgroundColor: "transparent" },
    },
    { dark }
  );
}

// Markdown-aware highlight style: emphasise headings/bold/links so the prose
// reads like formatted text, while keeping markdown punctuation subtle.
function makeHighlight(dark) {
  const heading = dark ? "#f2f2f7" : "#000000";
  const accent = dark ? "#7ab0ff" : "#0a66d0";
  const muted = dark ? "#8a8a8e" : "#9a9aa0";
  const codeColor = dark ? "#d6b3ff" : "#7a3ed6";
  return HighlightStyle.define([
    { tag: t.heading1, fontSize: "1.7em", fontWeight: "700", color: heading },
    { tag: t.heading2, fontSize: "1.4em", fontWeight: "700", color: heading },
    { tag: t.heading3, fontSize: "1.2em", fontWeight: "600", color: heading },
    { tag: [t.heading4, t.heading5, t.heading6], fontWeight: "600", color: heading },
    { tag: t.strong, fontWeight: "700" },
    { tag: t.emphasis, fontStyle: "italic" },
    { tag: t.strikethrough, textDecoration: "line-through" },
    { tag: [t.link, t.url], color: accent, textDecoration: "underline" },
    { tag: t.monospace, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: codeColor },
    { tag: t.quote, color: muted, fontStyle: "italic" },
    { tag: [t.processingInstruction, t.meta], color: muted },
    { tag: t.list, color: accent },
  ]);
}

// ── Editor construction ──────────────────────────────────────────────────
const changeListener = EditorView.updateListener.of((update) => {
  if (update.docChanged) {
    scheduleChange(update.state.doc.toString());
  }
});

const startDark = matchMediaDark();

const state = EditorState.create({
  doc: "",
  extensions: [
    history(),
    keymap.of([...defaultKeymap, ...historyKeymap]),
    markdown({ base: markdownLanguage }),
    EditorView.lineWrapping,
    proseBase,
    themeCompartment.of(makeTheme(startDark)),
    highlightCompartment.of(syntaxHighlighting(makeHighlight(startDark))),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    changeListener,
  ],
});

const view = new EditorView({
  state,
  parent: document.getElementById("editor"),
});

function matchMediaDark() {
  try {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  } catch (e) {
    return false;
  }
}

// ── native -> JS API ───────────────────────────────────────────────────────
// Replace the whole document without emitting a change back to native (avoids
// an echo loop when native pushes the initial / externally-changed text).
window.scribeSetDoc = function (text) {
  const next = typeof text === "string" ? text : "";
  if (next === view.state.doc.toString()) return;
  if (changeTimer !== null) {
    clearTimeout(changeTimer);
    changeTimer = null;
  }
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: next },
  });
};

window.scribeSetTheme = function (mode) {
  const dark = mode === "dark";
  view.dispatch({
    effects: [
      themeCompartment.reconfigure(makeTheme(dark)),
      highlightCompartment.reconfigure(syntaxHighlighting(makeHighlight(dark))),
    ],
  });
  document.documentElement.dataset.theme = dark ? "dark" : "light";
};

window.scribeFocus = function () {
  view.focus();
};

// Tell native we're mounted and ready to receive doc/theme.
postToNative({ type: "ready" });
