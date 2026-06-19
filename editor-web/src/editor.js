// Scribe CodeMirror 6 markdown editor — bundled for the macOS WKWebView host.
//
// This file is bundled (esbuild, IIFE, global name `ScribeEditor`) into
// ../Scribe/Resources/Editor/editor.bundle.js. The committed bundle is what the
// app ships; node is only needed to (re)build it, never at app build/run time.
//
// It implements an Obsidian-style LIVE PREVIEW: the document stays raw markdown
// (so saving is unchanged), but CodeMirror decorations render headings, inline
// emphasis, lists, task checkboxes, blockquotes/callouts, wiki-links, fenced
// mermaid/plantuml diagrams, and KaTeX math. Syntax markers (`#`, `**`, `*`,
// `` ` ``, list bullets, `>`) are HIDDEN on lines that don't hold the
// cursor/selection and REVEALED on the active line — the core live-preview
// behavior.
//
// Native bridge contract:
//   JS -> native:  window.webkit.messageHandlers.scribe.postMessage({type, ...})
//                  - {type:"ready"}             once the editor is mounted
//                  - {type:"change", text}      debounced, on every doc edit
//                  - {type:"wikilink", target}  user clicked a [[wiki link]]
//   native -> JS:  window.scribeSetDoc(text)    replace the whole document
//                  window.scribeSetTheme("light"|"dark")
//                  window.scribeSetFontSize(px) optional body font-size override
//                  window.scribeFocus()         focus the editor

import { EditorView, keymap, Decoration, WidgetType, ViewPlugin } from "@codemirror/view";
import { EditorState, Compartment, RangeSetBuilder, StateEffect, StateField } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import {
  syntaxHighlighting,
  defaultHighlightStyle,
  HighlightStyle,
  syntaxTree,
} from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { tags as t } from "@lezer/highlight";
import katex from "katex";
import { injectKatexCSS } from "./katex-css.js";
import { getDiagram, onDiagramRendered } from "./diagrams.js";

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
const themeCompartment = new Compartment();
const highlightCompartment = new Compartment();
const fontSizeCompartment = new Compartment();
let currentDark = matchMediaDark();

const proseBase = EditorView.theme({
  "&": { height: "100%" },
  ".cm-scroller": {
    fontFamily:
      '-apple-system, "SF Pro Text", "Helvetica Neue", "Segoe UI", system-ui, sans-serif',
    lineHeight: "1.7",
    overflow: "auto",
  },
  ".cm-content": {
    maxWidth: "44rem",
    margin: "0 auto",
    padding: "2.5rem 1.75rem 6rem",
    caretColor: "var(--scribe-caret)",
  },
  ".cm-line": { padding: "0 0" },
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
        "--scribe-accent-soft": dark ? "rgba(122,176,255,0.16)" : "rgba(10,102,208,0.10)",
        "--scribe-unresolved": dark ? "#d98b8b" : "#c0392b",
        "--scribe-unresolved-soft": dark ? "rgba(217,139,139,0.14)" : "rgba(192,57,43,0.08)",
        "--scribe-quote-bar": dark ? "#4a4a52" : "#d8d8de",
        "--scribe-quote-bg": dark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.03)",
        "--scribe-code-bg": dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)",
        "--scribe-panel-bg": dark ? "rgba(255,255,255,0.05)" : "rgba(0,0,0,0.035)",
        "--scribe-panel-border": dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.08)",
        "--scribe-hr": dark ? "#3a3a3f" : "#dcdce2",
        "--scribe-menu-bg": dark ? "#2b2b30" : "#ffffff",
        "--scribe-menu-border": dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)",
        "--scribe-menu-sel": dark ? "rgba(122,176,255,0.22)" : "rgba(10,102,208,0.12)",
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
  listLine: "cm-sl-listline",
};

const hideMark = Decoration.replace({});

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

class TaskWidget extends WidgetType {
  constructor(checked, pos) {
    super();
    this.checked = checked;
    this.pos = pos;
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
      e.preventDefault();
      const insert = this.checked ? " " : "x";
      view.dispatch({ changes: { from: this.pos, to: this.pos + 1, insert } });
    });
    return box;
  }
  ignoreEvent() {
    return true;
  }
}

// Clickable wiki-link [[Title]] / [[Title|alias]]. `resolved` styles known vs
// broken links; clicking posts the lookup title to native for navigation.
class WikiLinkWidget extends WidgetType {
  constructor(target, label, resolved) {
    super();
    this.target = target;
    this.label = label;
    this.resolved = resolved;
  }
  eq(other) {
    return (
      other.target === this.target &&
      other.label === this.label &&
      other.resolved === this.resolved
    );
  }
  toDOM() {
    const a = document.createElement("span");
    a.className = "cm-sl-wikilink" + (this.resolved ? "" : " cm-sl-wikilink-unresolved");
    a.textContent = this.label;
    a.setAttribute("role", "link");
    a.setAttribute("title", this.resolved ? this.target : `${this.target} (not found)`);
    a.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      postToNative({ type: "wikilink", target: this.target });
    });
    return a;
  }
  ignoreEvent() {
    return true;
  }
}

// KaTeX math widget ($...$ inline, $$...$$ block).
class MathWidget extends WidgetType {
  constructor(src, display) {
    super();
    this.src = src;
    this.display = display;
  }
  eq(other) {
    return other.src === this.src && other.display === this.display;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = this.display ? "cm-sl-math cm-sl-math-block" : "cm-sl-math";
    try {
      katex.render(this.src, span, {
        displayMode: this.display,
        throwOnError: false,
        output: "html",
      });
    } catch (e) {
      span.textContent = this.src;
      span.classList.add("cm-sl-math-error");
    }
    return span;
  }
  ignoreEvent() {
    return true;
  }
}

// Rendered diagram (mermaid offline / plantuml via <img>). Async results arrive
// through the diagram cache; onDiagramRendered triggers a re-decoration.
class DiagramWidget extends WidgetType {
  constructor(kind, src, dark) {
    super();
    this.kind = kind;
    this.src = src;
    this.dark = dark;
  }
  eq(other) {
    return other.kind === this.kind && other.src === this.src && other.dark === this.dark;
  }
  toDOM() {
    const wrap = document.createElement("div");
    wrap.className = "cm-sl-diagram";
    const entry = getDiagram(this.kind, this.src, this.dark);
    if (entry.status === "pending") {
      wrap.classList.add("cm-sl-diagram-pending");
      wrap.textContent = `Rendering ${this.kind}…`;
    } else if (entry.status === "error") {
      wrap.classList.add("cm-sl-diagram-error");
      const pre = document.createElement("pre");
      pre.textContent = `${this.kind} error: ${entry.error}\n\n${this.src}`;
      wrap.appendChild(pre);
    } else if (entry.svg) {
      wrap.innerHTML = entry.svg;
    } else if (entry.url) {
      const img = document.createElement("img");
      img.src = entry.url;
      img.alt = "PlantUML diagram";
      img.className = "cm-sl-diagram-img";
      img.addEventListener("error", () => {
        wrap.classList.add("cm-sl-diagram-error");
        wrap.textContent = "PlantUML render failed (offline?)";
      });
      wrap.appendChild(img);
    }
    return wrap;
  }
  ignoreEvent() {
    return true;
  }
}

const HEADING_CLASS = [CL.h1, CL.h2, CL.h3, CL.h4, CL.h5, CL.h6];

// Wiki-link resolution: native pushes the set of known note titles (lowercased)
// so we can style resolved vs broken links. Held in a StateField.
const setKnownTitles = StateEffect.define();
const knownTitlesField = StateField.define({
  create() {
    return new Set();
  },
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setKnownTitles)) return e.value;
    }
    return value;
  },
});

function buildDecorations(view) {
  const { state } = view;
  const deco = [];
  const known = state.field(knownTitlesField, false) || new Set();

  const activeLines = new Set();
  for (const range of state.selection.ranges) {
    const a = state.doc.lineAt(range.from).number;
    const b = state.doc.lineAt(range.to).number;
    for (let n = a; n <= b; n++) activeLines.add(n);
  }
  const lineActive = (pos) => activeLines.has(state.doc.lineAt(pos).number);
  // A range spanning multiple lines (fenced block) is "active" if any of its
  // lines hold the cursor — used to reveal diagram/math source for editing.
  const rangeActive = (from, to) => {
    const a = state.doc.lineAt(from).number;
    const b = state.doc.lineAt(to).number;
    for (let n = a; n <= b; n++) if (activeLines.has(n)) return true;
    return false;
  };

  const hide = (from, to) => {
    if (from >= to) return;
    if (lineActive(from)) return;
    deco.push({ from, to, value: hideMark, sortSide: -2 });
  };

  // Track fenced-code ranges we replace with a diagram so we can skip emitting
  // inner decorations for them.
  const consumed = [];
  const isConsumed = (from) => consumed.some((c) => from >= c.from && from < c.to);

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const name = node.name;
        const nFrom = node.from;
        const nTo = node.to;

        if (isConsumed(nFrom)) return;

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
            // Hide the leading `#`+space markers when the line is inactive.
            // (HeaderMark is also emitted as a child node, but the lezer markdown
            // grammar does not always surface it for every heading shape; do it
            // here too so a stray `#` never leaks through — the original bug.)
            const lineText = line.text;
            const m = lineText.match(/^(#{1,6})(\s+)/);
            if (m) {
              hide(line.from, line.from + m[0].length);
            }
            break;
          }

          case "HeaderMark": {
            let end = nTo;
            const after = state.doc.sliceString(nTo, Math.min(nTo + 1, state.doc.length));
            if (after === " ") end = nTo + 1;
            hide(nFrom, end);
            break;
          }

          case "QuoteMark": {
            let end = nTo;
            const after = state.doc.sliceString(nTo, Math.min(nTo + 1, state.doc.length));
            if (after === " ") end = nTo + 1;
            hide(nFrom, end);
            break;
          }

          case "Blockquote": {
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
            deco.push({
              from: nFrom,
              to: nTo,
              value: Decoration.mark({ class: CL.code }),
              sortSide: 0,
            });
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

          case "FencedCode": {
            maybeDecorateFence(state, deco, node, rangeActive, consumed);
            break;
          }

          default:
            break;
        }
      },
    });
  }

  // Inline regex passes (wiki-links + math) — lezer markdown doesn't parse these
  // natively, so we scan the visible text. Skip ranges inside fenced code.
  decorateInlinePatterns(view, deco, known, lineActive, isConsumed);

  deco.sort((a, b) => a.from - b.from || a.sortSide - b.sortSide);
  const builder = new RangeSetBuilder();
  for (const d of deco) builder.add(d.from, d.to, d.value);
  return builder.finish();
}

function applyInline(state, deco, from, to, cls, markerLen, hide) {
  deco.push({ from, to, value: Decoration.mark({ class: cls }), sortSide: 0 });
  hide(from, from + markerLen);
  hide(to - markerLen, to);
}

function decorateListItem(view, state, deco, node, lineActive) {
  const { from } = node;
  const line = state.doc.lineAt(from);
  const lineText = line.text;

  deco.push({
    from: line.from,
    to: line.from,
    value: Decoration.line({ class: CL.listLine }),
    sortSide: -10,
  });

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

  const taskMatch = lineText.match(/^(\s*)([-*+])\s+\[([ xX])\]\s/);
  if (taskMatch && markFrom >= 0) {
    const checked = taskMatch[3].toLowerCase() === "x";
    const openBracket = line.from + lineText.indexOf("[");
    const innerPos = openBracket + 1;
    if (!lineActive(line.from)) {
      const hideEnd = line.from + taskMatch[0].length;
      deco.push({
        from: markFrom,
        to: hideEnd,
        value: Decoration.replace({ widget: new TaskWidget(checked, innerPos) }),
        sortSide: -1,
      });
    }
    return;
  }

  if (markFrom >= 0 && !ordered) {
    if (!lineActive(line.from)) {
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
}

// Render a ```mermaid``` / ```plantuml``` fence as a diagram widget unless the
// caret is inside it (then leave raw source for editing).
function maybeDecorateFence(state, deco, node, rangeActive, consumed) {
  const text = state.doc.sliceString(node.from, node.to);
  const m = text.match(/^```[ \t]*([A-Za-z0-9_-]+)?[^\n]*\n([\s\S]*?)\n?```[ \t]*$/);
  if (!m) return;
  const lang = (m[1] || "").toLowerCase();
  if (lang !== "mermaid" && lang !== "plantuml") return;
  consumed.push({ from: node.from, to: node.to });
  if (rangeActive(node.from, node.to)) return; // editing — show source
  const src = m[2] || "";
  if (!src.trim()) return;
  // Replace the whole fenced block (block widget) with the rendered diagram.
  deco.push({
    from: node.from,
    to: node.to,
    value: Decoration.replace({
      widget: new DiagramWidget(lang, src, currentDark),
      block: true,
    }),
    sortSide: -1,
  });
}

const WIKILINK_RE = /\[\[([^\[\]\n]+)\]\]/g;
// $$...$$ (block) first, then single $...$ (inline, no spaces just inside, not
// part of a $$). Kept simple/robust per the brief.
const MATH_BLOCK_RE = /\$\$([^\n]+?)\$\$/g;
const MATH_INLINE_RE = /(?<!\$)\$(?!\s)([^\n$]+?)(?<!\s)\$(?!\$)/g;

function decorateInlinePatterns(view, deco, known, lineActive, isConsumed) {
  const { state } = view;
  for (const { from, to } of view.visibleRanges) {
    const text = state.doc.sliceString(from, to);

    // Wiki-links.
    WIKILINK_RE.lastIndex = 0;
    let m;
    while ((m = WIKILINK_RE.exec(text)) !== null) {
      const start = from + m.index;
      const end = start + m[0].length;
      if (isConsumed(start)) continue;
      const inner = m[1];
      const pipe = inner.indexOf("|");
      const target = (pipe >= 0 ? inner.slice(0, pipe) : inner).trim();
      const label = (pipe >= 0 ? inner.slice(pipe + 1) : inner).trim();
      const resolved = known.has(target.toLowerCase());
      if (lineActive(start)) {
        // Active line: keep raw text editable, just tint it.
        deco.push({
          from: start,
          to: end,
          value: Decoration.mark({
            class: resolved ? "cm-sl-wikilink-raw" : "cm-sl-wikilink-raw cm-sl-wikilink-unresolved",
          }),
          sortSide: 0,
        });
      } else {
        deco.push({
          from: start,
          to: end,
          value: Decoration.replace({ widget: new WikiLinkWidget(target, label, resolved) }),
          sortSide: -1,
        });
      }
    }

    // Block math $$...$$.
    MATH_BLOCK_RE.lastIndex = 0;
    const blockSpans = [];
    while ((m = MATH_BLOCK_RE.exec(text)) !== null) {
      const start = from + m.index;
      const end = start + m[0].length;
      if (isConsumed(start)) continue;
      blockSpans.push([start, end]);
      if (lineActive(start)) continue;
      deco.push({
        from: start,
        to: end,
        value: Decoration.replace({ widget: new MathWidget(m[1].trim(), true) }),
        sortSide: -1,
      });
    }

    // Inline math $...$ (skip anything overlapping a $$ block span).
    MATH_INLINE_RE.lastIndex = 0;
    while ((m = MATH_INLINE_RE.exec(text)) !== null) {
      const start = from + m.index;
      const end = start + m[0].length;
      if (isConsumed(start)) continue;
      if (blockSpans.some(([s, e]) => start >= s && start < e)) continue;
      if (lineActive(start)) continue;
      deco.push({
        from: start,
        to: end,
        value: Decoration.replace({ widget: new MathWidget(m[1].trim(), false) }),
        sortSide: -1,
      });
    }
  }
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
        update.viewportChanged ||
        update.transactions.some((tr) =>
          tr.effects.some((e) => e.is(setKnownTitles) || e.is(diagramReady))
        )
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

// Effect used purely to nudge a re-decoration when an async diagram resolves.
const diagramReady = StateEffect.define();

// ── Slash command menu ──────────────────────────────────────────────────────
// Self-contained in-web menu: typing `/` at the start of an empty-ish line shows
// a command list; each command inserts the corresponding markdown.

const SLASH_COMMANDS = [
  { id: "h1", label: "Heading 1", hint: "#", run: (v) => replaceLinePrefix(v, "# ") },
  { id: "h2", label: "Heading 2", hint: "##", run: (v) => replaceLinePrefix(v, "## ") },
  { id: "h3", label: "Heading 3", hint: "###", run: (v) => replaceLinePrefix(v, "### ") },
  { id: "bullet", label: "Bulleted List", hint: "-", run: (v) => replaceLinePrefix(v, "- ") },
  { id: "numbered", label: "Numbered List", hint: "1.", run: (v) => replaceLinePrefix(v, "1. ") },
  { id: "task", label: "Task List", hint: "[ ]", run: (v) => replaceLinePrefix(v, "- [ ] ") },
  { id: "quote", label: "Quote", hint: ">", run: (v) => replaceLinePrefix(v, "> ") },
  { id: "code", label: "Code Block", hint: "```", run: (v) => insertBlock(v, "```\n", "\n```") },
  { id: "divider", label: "Divider", hint: "---", run: (v) => replaceLineWith(v, "---\n") },
  { id: "table", label: "Table", hint: "▦", run: (v) => insertBlock(v, "| Column | Column |\n| --- | --- |\n| ", " |  |") },
  { id: "link", label: "Link", hint: "[ ]( )", run: (v) => insertInline(v, "[", "](url)") },
  { id: "math", label: "Math Block", hint: "$$", run: (v) => insertBlock(v, "$$\n", "\n$$") },
  { id: "mermaid", label: "Mermaid Diagram", hint: "</>", run: (v) => insertBlock(v, "```mermaid\n", "\n```") },
  { id: "wikilink", label: "Wiki Link", hint: "[[ ]]", run: (v) => insertInline(v, "[[", "]]") },
];

// Replace the active line's leading text up to the cursor with `prefix`.
function replaceLinePrefix(view, prefix) {
  const range = view.state.selection.main;
  const line = view.state.doc.lineAt(range.head);
  view.dispatch({
    changes: { from: line.from, to: range.head, insert: prefix },
    selection: { anchor: line.from + prefix.length },
  });
}

function replaceLineWith(view, text) {
  const range = view.state.selection.main;
  const line = view.state.doc.lineAt(range.head);
  view.dispatch({
    changes: { from: line.from, to: range.head, insert: text },
    selection: { anchor: line.from + text.length },
  });
}

function insertBlock(view, before, after) {
  const range = view.state.selection.main;
  const line = view.state.doc.lineAt(range.head);
  const insert = before + after;
  view.dispatch({
    changes: { from: line.from, to: range.head, insert },
    selection: { anchor: line.from + before.length },
  });
}

function insertInline(view, before, after) {
  const range = view.state.selection.main;
  view.dispatch({
    changes: { from: range.head, to: range.head, insert: before + after },
    selection: { anchor: range.head + before.length },
  });
}

const slashMenu = (() => {
  let dom = null;
  let active = false;
  let filtered = [];
  let selected = 0;
  let slashPos = -1; // doc pos of the `/` that opened the menu
  let editorView = null;

  function ensureDom() {
    if (dom) return dom;
    dom = document.createElement("div");
    dom.className = "cm-sl-slashmenu";
    dom.setAttribute("role", "listbox");
    document.body.appendChild(dom);
    return dom;
  }

  function close() {
    active = false;
    slashPos = -1;
    if (dom) dom.style.display = "none";
  }

  function render() {
    const el = ensureDom();
    el.innerHTML = "";
    if (!filtered.length) {
      close();
      return;
    }
    filtered.forEach((cmd, i) => {
      const item = document.createElement("div");
      item.className = "cm-sl-slashitem" + (i === selected ? " cm-sl-slashitem-sel" : "");
      item.setAttribute("role", "option");
      const label = document.createElement("span");
      label.className = "cm-sl-slashlabel";
      label.textContent = cmd.label;
      const hint = document.createElement("span");
      hint.className = "cm-sl-slashhint";
      hint.textContent = cmd.hint;
      item.appendChild(label);
      item.appendChild(hint);
      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        choose(i);
      });
      el.appendChild(item);
    });
    el.style.display = "block";
    position();
  }

  function position() {
    if (!editorView || slashPos < 0) return;
    const coords = editorView.coordsAtPos(slashPos);
    if (!coords) return;
    const el = ensureDom();
    el.style.left = `${Math.round(coords.left)}px`;
    el.style.top = `${Math.round(coords.bottom + 4)}px`;
  }

  function choose(i) {
    const cmd = filtered[i];
    if (!cmd || !editorView) return close();
    // Remove the `/query` text first, then run the command at line context.
    const head = editorView.state.selection.main.head;
    editorView.dispatch({ changes: { from: slashPos, to: head, insert: "" } });
    cmd.run(editorView);
    editorView.focus();
    close();
  }

  // Called from the update listener to (re)evaluate menu state from the doc.
  function sync(view) {
    editorView = view;
    const sel = view.state.selection.main;
    if (!sel.empty) {
      if (active) close();
      return;
    }
    const head = sel.head;
    const line = view.state.doc.lineAt(head);
    const before = view.state.doc.sliceString(line.from, head);
    // Trigger: `/` is the first non-space char on the line (slash command).
    const match = before.match(/(?:^|\s)\/([A-Za-z0-9]*)$/);
    const lineStartSlash = /^\s*\/([A-Za-z0-9]*)$/.test(before);
    if (lineStartSlash && match) {
      slashPos = line.from + before.lastIndexOf("/");
      const q = match[1].toLowerCase();
      filtered = SLASH_COMMANDS.filter(
        (c) => !q || c.id.includes(q) || c.label.toLowerCase().includes(q)
      );
      selected = 0;
      active = filtered.length > 0;
      if (active) render();
      else close();
    } else if (active) {
      close();
    }
  }

  function keydown(e, view) {
    if (!active) return false;
    if (e.key === "ArrowDown") {
      selected = (selected + 1) % filtered.length;
      render();
      e.preventDefault();
      return true;
    }
    if (e.key === "ArrowUp") {
      selected = (selected - 1 + filtered.length) % filtered.length;
      render();
      e.preventDefault();
      return true;
    }
    if (e.key === "Enter" || e.key === "Tab") {
      choose(selected);
      e.preventDefault();
      return true;
    }
    if (e.key === "Escape") {
      close();
      e.preventDefault();
      return true;
    }
    return false;
  }

  return { sync, keydown, close, isActive: () => active };
})();

const slashDomHandlers = EditorView.domEventHandlers({
  keydown: (e, view) => slashMenu.keydown(e, view),
  blur: () => {
    // Defer so a menu mousedown (which fires before blur) can still choose.
    setTimeout(() => slashMenu.close(), 120);
  },
});

const slashSyncListener = EditorView.updateListener.of((update) => {
  if (update.docChanged || update.selectionSet) {
    slashMenu.sync(update.view);
  }
});

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
    knownTitlesField,
    proseBase,
    fontSizeCompartment.of(makeFontSize(17)),
    themeCompartment.of(makeTheme(startDark)),
    highlightCompartment.of(syntaxHighlighting(makeHighlight(startDark))),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    livePreviewPlugin,
    slashDomHandlers,
    slashSyncListener,
    changeListener,
  ],
});

const view = new EditorView({
  state,
  parent: document.getElementById("editor"),
});

// Re-decorate when an async diagram (mermaid/plantuml) finishes rendering.
onDiagramRendered(() => {
  view.dispatch({ effects: diagramReady.of(null) });
});

function matchMediaDark() {
  try {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  } catch (e) {
    return false;
  }
}

// KaTeX CSS injected once at startup so math renders offline.
injectKatexCSS();

// ── native -> JS API ───────────────────────────────────────────────────────
window.scribeSetDoc = function (text) {
  const next = typeof text === "string" ? text : "";
  if (next === view.state.doc.toString()) return;
  if (changeTimer !== null) {
    clearTimeout(changeTimer);
    changeTimer = null;
  }
  slashMenu.close();
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: next },
  });
};

window.scribeSetTheme = function (mode) {
  const dark = mode === "dark";
  currentDark = dark;
  view.dispatch({
    effects: [
      themeCompartment.reconfigure(makeTheme(dark)),
      highlightCompartment.reconfigure(syntaxHighlighting(makeHighlight(dark))),
      diagramReady.of(null), // re-render diagrams in the new theme
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

// Native pushes the set of known note titles so wiki-links can be styled as
// resolved vs broken. Accepts an array of titles.
window.scribeSetKnownTitles = function (titles) {
  const set = new Set();
  if (Array.isArray(titles)) {
    for (const titleString of titles) {
      if (typeof titleString === "string") set.add(titleString.trim().toLowerCase());
    }
  }
  view.dispatch({ effects: setKnownTitles.of(set) });
};

// Tell native we're mounted and ready to receive doc/theme.
postToNative({ type: "ready" });
