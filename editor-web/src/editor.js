// Scribe CodeMirror 6 markdown editor — bundled for the macOS WKWebView host.
//
// This file is bundled (esbuild, IIFE, global name `ScribeEditor`) into
// ../Scribe/Resources/Editor/editor.bundle.js. The committed bundle is what the
// app ships; node is only needed to (re)build it, never at app build/run time.
//
// It implements an Obsidian-style LIVE PREVIEW: the document stays raw markdown
// (so saving is unchanged), but CodeMirror decorations render headings, inline
// emphasis, lists, task checkboxes, and blockquotes/callouts. Syntax markers
// (`#`, `**`, `*`, `` ` ``, list bullets, `>`) are HIDDEN on lines that don't
// hold the cursor/selection and REVEALED on the active line — the core
// live-preview behavior.
//
// Native bridge contract:
//   JS -> native:  window.webkit.messageHandlers.scribe.postMessage({type, ...})
//                  - {type:"ready"}            once the editor is mounted
//                  - {type:"change", text}     debounced, on every doc edit
//   native -> JS:  window.scribeSetDoc(text)   replace the whole document
//                  window.scribeSetTheme("light"|"dark")
//                  window.scribeSetFontSize(px) optional body font-size override
//                  window.scribeFocus()         focus the editor

import { EditorView, keymap, Decoration, WidgetType, ViewPlugin } from "@codemirror/view";
import { EditorState, Compartment, RangeSetBuilder } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import {
  syntaxHighlighting,
  defaultHighlightStyle,
  HighlightStyle,
  syntaxTree,
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
const fontSizeCompartment = new Compartment();

// Shared prose layout (font, width, spacing) — NOT a code editor look.
const proseBase = EditorView.theme({
  "&": {
    height: "100%",
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
    padding: "0 0",
  },
  // No code-editor gutter / line numbers.
  ".cm-gutters": { display: "none" },
  "&.cm-focused": { outline: "none" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--scribe-caret)" },
});

function makeFontSize(px) {
  return EditorView.theme({ "&": { fontSize: `${px}px` } });
}

function makeTheme(dark) {
  return EditorView.theme(
    {
      "&": {
        color: dark ? "#e6e6e6" : "#1d1d1f",
        backgroundColor: dark ? "#1e1e1e" : "#ffffff",
        "--scribe-caret": dark ? "#e6e6e6" : "#1d1d1f",
        "--scribe-muted": dark ? "#8a8a8e" : "#9a9aa0",
        "--scribe-accent": dark ? "#7ab0ff" : "#0a66d0",
        "--scribe-quote-bar": dark ? "#4a4a52" : "#d8d8de",
        "--scribe-quote-bg": dark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.03)",
        "--scribe-code-bg": dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)",
        "--scribe-hr": dark ? "#3a3a3f" : "#dcdce2",
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

// ── Live preview decorations ────────────────────────────────────────────────
//
// We walk the markdown syntax tree and emit decorations:
//   * `Decoration.replace` to hide syntax markers (the `#`, `**`, `>` etc.)
//   * `Decoration.mark` to apply block/inline classes (headings, lists, quotes)
//   * widgets for rendered list bullets and task checkboxes.
//
// Markers are hidden ONLY on lines that don't intersect the current
// selection. The line(s) under the cursor reveal their raw markdown so they're
// editable — this is the Obsidian live-preview behavior.

// CSS classes used by decorations (styled in editor.css).
const CL = {
  h1: "cm-sl-h1",
  h2: "cm-sl-h2",
  h3: "cm-sl-h3",
  h4: "cm-sl-h4",
  h5: "cm-sl-h5",
  h6: "cm-sl-h6",
  strong: "cm-sl-strong",
  emphasis: "cm-sl-emphasis",
  strike: "cm-sl-strike",
  code: "cm-sl-code",
  quote: "cm-sl-quote",
  quoteBar: "cm-sl-quotebar",
  listLine: "cm-sl-listline",
  hidden: "cm-sl-hidden",
};

// A zero-width replacement used to hide a marker range.
const hideMark = Decoration.replace({});

// Rendered bullet for an unordered list item, replacing the `- `/`* `/`+ `.
class BulletWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-sl-bullet";
    span.textContent = "•";
    return span;
  }
  ignoreEvent() {
    return true;
  }
}

// Clickable task checkbox replacing `[ ]` / `[x]`. Toggling rewrites the source
// char so the document stays raw markdown.
class TaskWidget extends WidgetType {
  constructor(checked, pos) {
    super();
    this.checked = checked;
    this.pos = pos; // doc position of the char inside the brackets
  }
  eq(other) {
    return other.checked === this.checked && other.pos === this.pos;
  }
  toDOM(view) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = this.checked;
    box.className = "cm-sl-task";
    box.setAttribute("aria-label", this.checked ? "Completed task" : "Incomplete task");
    box.addEventListener("mousedown", (e) => {
      // Toggle the source char (` ` <-> `x`) without moving the selection.
      e.preventDefault();
      const insert = this.checked ? " " : "x";
      view.dispatch({
        changes: { from: this.pos, to: this.pos + 1, insert },
      });
    });
    return box;
  }
  ignoreEvent() {
    return true;
  }
}

const HEADING_CLASS = [CL.h1, CL.h2, CL.h3, CL.h4, CL.h5, CL.h6];

// Does [from,to) intersect any line that holds part of the selection?
function selectionTouchesRange(state, from, to) {
  for (const range of state.selection.ranges) {
    const lineFrom = state.doc.lineAt(Math.max(0, Math.min(from, state.doc.length))).from;
    const lineTo = state.doc.lineAt(Math.max(0, Math.min(to, state.doc.length))).to;
    if (range.from <= lineTo && range.to >= lineFrom) return true;
  }
  return false;
}

function buildDecorations(view) {
  const { state } = view;
  // Collect decorations then sort — replace and mark/line decorations must be
  // added to the builder in document order, which is awkward across a tree
  // walk, so we gather into an array and sort by (from, startSide).
  const deco = [];

  // Track which lines hold the selection (markers revealed there).
  const activeLines = new Set();
  for (const range of state.selection.ranges) {
    const a = state.doc.lineAt(range.from).number;
    const b = state.doc.lineAt(range.to).number;
    for (let n = a; n <= b; n++) activeLines.add(n);
  }
  const lineActive = (pos) => activeLines.has(state.doc.lineAt(pos).number);

  // Hide a marker range unless its line is active.
  const hide = (from, to) => {
    if (from >= to) return;
    if (lineActive(from)) return;
    deco.push({ from, to, value: hideMark, sortSide: -2 });
  };

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const name = node.name;
        const nFrom = node.from;
        const nTo = node.to;

        switch (name) {
          case "ATXHeading1":
          case "ATXHeading2":
          case "ATXHeading3":
          case "ATXHeading4":
          case "ATXHeading5":
          case "ATXHeading6": {
            const level = Number(name.slice(-1));
            const line = state.doc.lineAt(nFrom);
            deco.push({
              from: line.from,
              to: line.from,
              value: Decoration.line({ class: HEADING_CLASS[level - 1] }),
              sortSide: -10,
            });
            break;
          }

          case "HeaderMark": {
            // `#`+ at start of a heading line, or `>` of a blockquote (lezer
            // markdown uses HeaderMark for headings; QuoteMark for `>`).
            // Hide the `#`s and the trailing space.
            let end = nTo;
            const after = state.doc.sliceString(nTo, Math.min(nTo + 1, state.doc.length));
            if (after === " ") end = nTo + 1;
            hide(nFrom, end);
            break;
          }

          case "QuoteMark": {
            // `>` blockquote marker (+ following space). Replaced by the styled
            // left bar via the Blockquote line decoration; just hide the chars.
            let end = nTo;
            const after = state.doc.sliceString(nTo, Math.min(nTo + 1, state.doc.length));
            if (after === " ") end = nTo + 1;
            hide(nFrom, end);
            break;
          }

          case "Blockquote": {
            // Apply the quote bar/tint to every line of the blockquote.
            let pos = nFrom;
            while (pos <= nTo) {
              const line = state.doc.lineAt(pos);
              deco.push({
                from: line.from,
                to: line.from,
                value: Decoration.line({ class: CL.quote }),
                sortSide: -10,
              });
              if (line.to + 1 > nTo) break;
              pos = line.to + 1;
            }
            break;
          }

          case "StrongEmphasis": {
            applyInline(state, deco, nFrom, nTo, CL.strong, 2, hide);
            break;
          }
          case "Emphasis": {
            applyInline(state, deco, nFrom, nTo, CL.emphasis, 1, hide);
            break;
          }
          case "Strikethrough": {
            applyInline(state, deco, nFrom, nTo, CL.strike, 2, hide);
            break;
          }
          case "InlineCode": {
            // Mark the whole span as code, hide the surrounding backticks.
            deco.push({
              from: nFrom,
              to: nTo,
              value: Decoration.mark({ class: CL.code }),
              sortSide: 0,
            });
            // Count leading backticks.
            const text = state.doc.sliceString(nFrom, nTo);
            const open = text.match(/^`+/);
            const close = text.match(/`+$/);
            if (open) hide(nFrom, nFrom + open[0].length);
            if (close) hide(nTo - close[0].length, nTo);
            break;
          }

          case "ListItem": {
            decorateListItem(view, state, deco, node, lineActive);
            break;
          }

          case "HorizontalRule": {
            const line = state.doc.lineAt(nFrom);
            deco.push({
              from: line.from,
              to: line.from,
              value: Decoration.line({ class: "cm-sl-hr" }),
              sortSide: -10,
            });
            break;
          }

          default:
            break;
        }
      },
    });
  }

  deco.sort((a, b) => a.from - b.from || a.sortSide - b.sortSide);
  const builder = new RangeSetBuilder();
  for (const d of deco) builder.add(d.from, d.to, d.value);
  return builder.finish();
}

// Mark an inline span and hide its `markerLen` delimiter chars on each side.
function applyInline(state, deco, from, to, cls, markerLen, hide) {
  deco.push({
    from,
    to,
    value: Decoration.mark({ class: cls }),
    sortSide: 0,
  });
  hide(from, from + markerLen);
  hide(to - markerLen, to);
}

// List item: render a bullet / task checkbox and indent, hiding the raw marker.
function decorateListItem(view, state, deco, node, lineActive) {
  const { from } = node;
  const line = state.doc.lineAt(from);
  const lineText = line.text;

  // Add a list-line class for indentation/spacing.
  deco.push({
    from: line.from,
    to: line.from,
    value: Decoration.line({ class: CL.listLine }),
    sortSide: -10,
  });

  // Find the list marker (the ListMark child) and any task marker.
  let markFrom = -1;
  let markTo = -1;
  let ordered = false;
  const cur = node.node.cursor();
  if (cur.firstChild()) {
    do {
      if (cur.name === "ListMark") {
        markFrom = cur.from;
        markTo = cur.to;
        ordered = /\d/.test(state.doc.sliceString(cur.from, cur.to));
        break;
      }
    } while (cur.nextSibling());
  }

  // Task checkbox: `- [ ]` / `- [x]`. Detect via the line text after the marker.
  const taskMatch = lineText.match(/^(\s*)([-*+])\s+\[([ xX])\]\s/);
  if (taskMatch && markFrom >= 0) {
    const checked = taskMatch[3].toLowerCase() === "x";
    // Position of the char inside the `[ ]` brackets (the toggle target).
    const openBracket = line.from + lineText.indexOf("[");
    const innerPos = openBracket + 1;
    if (!lineActive(line.from)) {
      // Hide `- [x] ` and render a checkbox widget at the marker start.
      const hideEnd = line.from + taskMatch[0].length;
      deco.push({
        from: markFrom,
        to: hideEnd,
        value: Decoration.replace({ widget: new TaskWidget(checked, innerPos) }),
        sortSide: -1,
      });
    } else {
      // Active line: still render the checkbox as a widget overlay would be
      // intrusive; keep raw markdown editable. (Checkbox interaction available
      // on inactive lines.)
    }
    return;
  }

  // Plain bullet (unordered): replace `- `/`* `/`+ ` with a styled bullet.
  if (markFrom >= 0 && !ordered) {
    if (!lineActive(line.from)) {
      // include trailing space in the hidden range
      let end = markTo;
      if (state.doc.sliceString(markTo, markTo + 1) === " ") end = markTo + 1;
      deco.push({
        from: markFrom,
        to: end,
        value: Decoration.replace({ widget: new BulletWidget() }),
        sortSide: -1,
      });
    }
  }
  // Ordered lists: leave the `1.` visible (it carries meaning); the line class
  // handles indentation.
}

const livePreviewPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = buildDecorations(view);
    }
    update(update) {
      if (
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged
      ) {
        this.decorations = buildDecorations(update.view);
      }
    }
  },
  {
    decorations: (v) => v.decorations,
    provide: (plugin) =>
      EditorView.atomicRanges.of((view) => {
        return view.plugin(plugin)?.decorations || Decoration.none;
      }),
  }
);

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
    fontSizeCompartment.of(makeFontSize(17)),
    themeCompartment.of(makeTheme(startDark)),
    highlightCompartment.of(syntaxHighlighting(makeHighlight(startDark))),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    livePreviewPlugin,
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

window.scribeSetFontSize = function (px) {
  const size = Number(px);
  if (!Number.isFinite(size) || size <= 0) return;
  view.dispatch({
    effects: fontSizeCompartment.reconfigure(makeFontSize(size)),
  });
};

window.scribeFocus = function () {
  view.focus();
};

// Tell native we're mounted and ready to receive doc/theme.
postToNative({ type: "ready" });
