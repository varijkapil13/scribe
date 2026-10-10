// Folding of headings (a heading folds its whole section, via lang-markdown's
// header fold service) and list items / other blocks (lang-markdown's
// foldNodeProp: a multi-line list item folds after its first line).
//
// UI: a slim fold gutter that only shows its chevrons on hover (prose editor,
// no line numbers) and ⌥⌘[ / ⌥⌘] to fold / unfold at the cursor (plus
// ⌃⌥[ / ⌃⌥] fold / unfold all, from the stock foldKeymap). Native-callable
// commands: fold, unfold, toggleFold, foldAll, unfoldAll.

import { EditorView, keymap } from "@codemirror/view";
import { Prec } from "@codemirror/state";
import {
  foldGutter,
  foldKeymap,
  codeFolding,
  foldCode,
  unfoldCode,
  toggleFold,
  foldAll,
  unfoldAll,
} from "@codemirror/language";
import { registerCommand } from "./bridge.js";

const foldTheme = EditorView.baseTheme({
  ".cm-gutters": {
    backgroundColor: "transparent",
    border: "none",
    color: "var(--scribe-muted, #9a9aa0)",
  },
  ".cm-foldGutter .cm-gutterElement": {
    padding: "0 2px 0 6px",
    cursor: "default",
    opacity: "0",
    transition: "opacity 120ms ease",
  },
  ".cm-gutters:hover .cm-foldGutter .cm-gutterElement": {
    opacity: "1",
  },
  ".cm-foldPlaceholder": {
    backgroundColor: "var(--scribe-code-bg, rgba(0,0,0,0.05))",
    border: "1px solid var(--scribe-panel-border, rgba(0,0,0,0.08))",
    color: "var(--scribe-muted, #9a9aa0)",
    borderRadius: "4px",
    padding: "0 6px",
    margin: "0 4px",
    cursor: "pointer",
  },
});

function marker(open) {
  const span = document.createElement("span");
  span.textContent = open ? "⌄" : "›"; // ⌄ open, › folded
  span.title = open ? "Fold" : "Unfold";
  if (!open) {
    // Folded chevrons stay visible without hover (see keepFoldedVisible).
    span.className = "cm-scribe-folded-marker";
  }
  return span;
}

const keepFoldedVisible = EditorView.baseTheme({
  ".cm-foldGutter .cm-gutterElement:has(.cm-scribe-folded-marker)": { opacity: "1" },
});

export function foldingExtensions() {
  return [
    codeFolding({ placeholderText: "…" }),
    foldGutter({ markerDOM: marker }),
    // ⌥⌘[ / ⌥⌘] (Mac bindings in the stock foldKeymap) above the defaults.
    Prec.high(keymap.of(foldKeymap)),
    foldTheme,
    keepFoldedVisible,
  ];
}

registerCommand("fold", (view) => foldCode(view));
registerCommand("unfold", (view) => unfoldCode(view));
registerCommand("toggleFold", (view) => toggleFold(view));
registerCommand("foldAll", (view) => foldAll(view));
registerCommand("unfoldAll", (view) => unfoldAll(view));
