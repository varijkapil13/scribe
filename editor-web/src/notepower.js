// Power-user note features for the Scribe editor:
//
// - `![[Note]]`, `![[Note#Heading]]`, `![[Note#^block-id]]` EMBEDS rendered
//   read-only inline in live preview. The widget asks native for the embedded
//   markdown ({type:"embedRequest", target}); native answers through the
//   command registry: window.scribeCommand("embedContent",
//   {target, found, title, markdown}). Answers are cached per target (and
//   refreshed after a short TTL or on "invalidateEmbeds").
// - "copyBlockLink" (arg {title}): links the block at the caret — adds a
//   `^id` anchor when the paragraph / list item has none (headings link by
//   their text) — and posts {type:"copyText", text:"[[Title#^id]]"} so native
//   puts it on the pasteboard.
// - "insertTemplate" (arg {text, cursor}): inserts rendered template text at
//   the selection, leaving the caret at `cursor` (UTF-16 offset in `text`).
// - "setCursorOffset" (arg {offset, docLength}): moves the caret, only when
//   the document still has the expected length (a freshly created note).
// - "invalidateEmbeds": drops the embed cache and re-renders embeds.

import { Decoration, EditorView, ViewPlugin, WidgetType } from "@codemirror/view";
import { RangeSetBuilder, StateEffect } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { postToNative, registerCommand } from "./bridge.js";
import { addTouchTap } from "./touch.js";

// ── Embed cache ─────────────────────────────────────────────────────────────

const EMBED_TTL_MS = 15000;
const embedCache = new Map(); // target -> {status, found, title, markdown, at, version}
let embedVersion = 0;
const embedUpdated = StateEffect.define();
let embedView = null;

function requestEmbed(target) {
  const now = Date.now();
  const entry = embedCache.get(target);
  if (entry && now - entry.at < EMBED_TTL_MS) return entry;
  const next = entry
    ? { ...entry, at: now, refreshing: true }
    : { status: "pending", found: false, title: "", markdown: "", at: now, version: embedVersion };
  embedCache.set(target, next);
  postToNative({ type: "embedRequest", target });
  return next;
}

function notifyEmbedsChanged() {
  if (!embedView) return;
  try {
    embedView.dispatch({ effects: embedUpdated.of(null) });
  } catch (e) {
    /* view torn down */
  }
}

registerCommand("embedContent", (view, arg) => {
  if (!arg || typeof arg.target !== "string") return false;
  embedVersion += 1;
  embedCache.set(arg.target, {
    status: "ready",
    found: arg.found === true,
    title: typeof arg.title === "string" ? arg.title : "",
    markdown: typeof arg.markdown === "string" ? arg.markdown : "",
    at: Date.now(),
    version: embedVersion,
  });
  notifyEmbedsChanged();
  return true;
});

registerCommand("invalidateEmbeds", () => {
  embedCache.clear();
  embedVersion += 1;
  notifyEmbedsChanged();
  return true;
});

// ── Read-only markdown rendering (DOM only, never innerHTML) ────────────────

function appendInline(parent, text) {
  // [[link|alias]] → alias / title; **bold**; *em* / _em_; `code`; [t](u) → t.
  const re = /(\[\[([^\[\]\n]+)\]\])|(\*\*([^*\n]+)\*\*)|(`([^`\n]+)`)|(\*([^*\n]+)\*)|(\[([^\]\n]+)\]\([^)\n]*\))/g;
  let last = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    if (m[1]) {
      const inner = m[2];
      const pipe = inner.indexOf("|");
      const span = document.createElement("span");
      span.className = "cm-sl-embed-link";
      span.textContent = (pipe >= 0 ? inner.slice(pipe + 1) : inner).trim();
      parent.appendChild(span);
    } else if (m[3]) {
      const b = document.createElement("strong");
      b.textContent = m[4];
      parent.appendChild(b);
    } else if (m[5]) {
      const c = document.createElement("code");
      c.textContent = m[6];
      parent.appendChild(c);
    } else if (m[7]) {
      const e = document.createElement("em");
      e.textContent = m[8];
      parent.appendChild(e);
    } else if (m[9]) {
      parent.appendChild(document.createTextNode(m[10]));
    }
    last = re.lastIndex;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
}

function renderMarkdownInto(container, markdown) {
  const lines = String(markdown || "").split("\n");
  let inFence = false;
  let pre = null;
  let paragraph = null;
  const flushParagraph = () => {
    paragraph = null;
  };
  for (const raw of lines) {
    const line = raw.replace(/\s+$/, "");
    if (/^\s*(```|~~~)/.test(line)) {
      if (inFence) {
        inFence = false;
        pre = null;
      } else {
        inFence = true;
        pre = document.createElement("pre");
        pre.className = "cm-sl-embed-pre";
        container.appendChild(pre);
      }
      flushParagraph();
      continue;
    }
    if (inFence) {
      pre.textContent += (pre.textContent ? "\n" : "") + raw;
      continue;
    }
    if (!line.trim()) {
      flushParagraph();
      continue;
    }
    const heading = line.match(/^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/);
    if (heading) {
      flushParagraph();
      const h = document.createElement("div");
      h.className = `cm-sl-embed-h cm-sl-embed-h${heading[1].length}`;
      appendInline(h, heading[2]);
      container.appendChild(h);
      continue;
    }
    const task = line.match(/^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$/);
    const bullet = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
    if (task || bullet) {
      flushParagraph();
      const item = document.createElement("div");
      item.className = "cm-sl-embed-li";
      const indent = (task ? task[1] : bullet[1]).replace(/\t/g, "    ").length;
      item.style.paddingLeft = `${1.1 + indent * 0.5}em`;
      const marker = document.createElement("span");
      marker.className = "cm-sl-embed-marker";
      if (task) marker.textContent = task[2].toLowerCase() === "x" ? "☑" : "☐";
      else marker.textContent = /\d/.test(bullet[2]) ? bullet[2] : "•";
      item.appendChild(marker);
      appendInline(item, task ? task[3] : bullet[3]);
      container.appendChild(item);
      continue;
    }
    const quote = line.match(/^\s*>\s?(.*)$/);
    if (quote) {
      flushParagraph();
      const q = document.createElement("div");
      q.className = "cm-sl-embed-quote";
      appendInline(q, quote[1]);
      container.appendChild(q);
      continue;
    }
    if (!paragraph) {
      paragraph = document.createElement("div");
      paragraph.className = "cm-sl-embed-p";
      container.appendChild(paragraph);
    } else {
      paragraph.appendChild(document.createTextNode(" "));
    }
    appendInline(paragraph, line.trim());
  }
}

// ── Embed widget ────────────────────────────────────────────────────────────

class EmbedWidget extends WidgetType {
  constructor(target, version) {
    super();
    this.target = target;
    this.version = version;
  }
  eq(other) {
    return other.target === this.target && other.version === this.version;
  }
  toDOM() {
    const entry = requestEmbed(this.target);
    const wrap = document.createElement("div");
    wrap.className = "cm-sl-embed";
    wrap.setAttribute("role", "group");

    const header = document.createElement("div");
    header.className = "cm-sl-embed-header";
    const title = document.createElement("span");
    title.className = "cm-sl-embed-title";
    title.textContent = entry.status === "ready" && entry.found && entry.title ? entry.title : this.target;
    title.setAttribute("role", "link");
    title.title = `Open ${this.target}`;
    title.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      postToNative({ type: "wikilink", target: this.target });
    });
    addTouchTap(title);
    header.appendChild(title);
    wrap.appendChild(header);
    wrap.setAttribute("aria-label", `Embedded note ${this.target}`);

    const body = document.createElement("div");
    body.className = "cm-sl-embed-body";
    if (entry.status !== "ready") {
      body.classList.add("cm-sl-embed-pending");
      body.textContent = "Loading…";
    } else if (!entry.found) {
      wrap.classList.add("cm-sl-embed-missing");
      body.textContent = "Not found";
    } else if (!entry.markdown.trim()) {
      body.classList.add("cm-sl-embed-pending");
      body.textContent = "Empty";
    } else {
      renderMarkdownInto(body, entry.markdown);
    }
    wrap.appendChild(body);
    return wrap;
  }
  ignoreEvent() {
    // Clicks on the body move the caret onto the line (revealing the raw
    // `![[…]]` for editing); the title handles its own mousedown.
    return false;
  }
}

const EMBED_RE = /!\[\[([^\[\]\n]+)\]\]/g;
// `![[photo.png]]`-style attachment embeds (Obsidian vaults) are not notes.
// Mirrors NoteEmbedExpander.isAttachmentAnchor (Swift).
const ATTACHMENT_EMBED_RE = /\.(png|jpe?g|gif|webp|svg|bmp|tiff?|heic|pdf|mp3|m4a|wav|aac|ogg|mp4|mov|m4v|webm)$/i;
function isAttachmentTarget(target) {
  return ATTACHMENT_EMBED_RE.test(target.split(/[#|]/)[0].trim());
}

function inCode(state, pos) {
  let node = syntaxTree(state).resolveInner(pos, 1);
  for (; node; node = node.parent) {
    const n = node.name;
    if (n === "FencedCode" || n === "CodeBlock" || n === "InlineCode" || n === "CodeText") return true;
  }
  return false;
}

function buildEmbedDecorations(view) {
  const { state } = view;
  const activeLines = new Set();
  for (const range of state.selection.ranges) {
    const a = state.doc.lineAt(range.from).number;
    const b = state.doc.lineAt(range.to).number;
    for (let n = a; n <= b; n++) activeLines.add(n);
  }
  const found = [];
  for (const { from, to } of view.visibleRanges) {
    const text = state.doc.sliceString(from, to);
    EMBED_RE.lastIndex = 0;
    let m;
    while ((m = EMBED_RE.exec(text)) !== null) {
      const start = from + m.index;
      const end = start + m[0].length;
      if (inCode(state, start)) continue;
      const target = m[1].trim();
      if (!target || isAttachmentTarget(target)) continue;
      if (activeLines.has(state.doc.lineAt(start).number)) {
        found.push({ from: start, to: end, deco: Decoration.mark({ class: "cm-sl-embed-raw" }) });
      } else {
        const entry = embedCache.get(target);
        const version = entry ? entry.version : -1;
        found.push({
          from: start,
          to: end,
          atomic: true,
          deco: Decoration.replace({ widget: new EmbedWidget(target, version) }),
        });
      }
    }
  }
  found.sort((a, b) => a.from - b.from);
  const builder = new RangeSetBuilder();
  // Only rendered (replaced) embeds are atomic: the raw `![[…]]` on the
  // active line must stay editable character by character.
  const atomic = new RangeSetBuilder();
  for (const f of found) {
    builder.add(f.from, f.to, f.deco);
    if (f.atomic) atomic.add(f.from, f.to, f.deco);
  }
  return { decorations: builder.finish(), atomic: atomic.finish() };
}

const embedPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      embedView = view;
      this.rebuild(view);
    }
    rebuild(view) {
      const built = buildEmbedDecorations(view);
      this.decorations = built.decorations;
      this.atomic = built.atomic;
    }
    update(update) {
      embedView = update.view;
      if (
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged ||
        update.transactions.some((tr) => tr.effects.some((e) => e.is(embedUpdated)))
      ) {
        this.rebuild(update.view);
      }
    }
  },
  {
    decorations: (v) => v.decorations,
    provide: (plugin) =>
      EditorView.atomicRanges.of((view) => view.plugin(plugin)?.atomic || Decoration.none),
  }
);

const embedTheme = EditorView.baseTheme({
  ".cm-sl-embed": {
    display: "block",
    margin: "0.35em 0",
    padding: "0.45em 0.8em 0.55em",
    borderLeft: "3px solid var(--scribe-accent, #0a66d0)",
    borderRadius: "6px",
    backgroundColor: "var(--scribe-panel-bg, rgba(0,0,0,0.035))",
    whiteSpace: "normal",
    cursor: "text",
  },
  ".cm-sl-embed-header": { fontSize: "0.8em", marginBottom: "0.25em" },
  ".cm-sl-embed-title": {
    color: "var(--scribe-accent, #0a66d0)",
    cursor: "pointer",
    fontWeight: "600",
  },
  ".cm-sl-embed-title:hover": { textDecoration: "underline" },
  ".cm-sl-embed-missing": {
    borderLeftColor: "var(--scribe-unresolved, #c0392b)",
    backgroundColor: "var(--scribe-unresolved-soft, rgba(192,57,43,0.08))",
  },
  ".cm-sl-embed-pending": { color: "var(--scribe-muted, #9a9aa0)", fontStyle: "italic" },
  ".cm-sl-embed-p": { margin: "0.15em 0" },
  ".cm-sl-embed-h": { fontWeight: "700", margin: "0.2em 0" },
  ".cm-sl-embed-h1": { fontSize: "1.3em" },
  ".cm-sl-embed-h2": { fontSize: "1.15em" },
  ".cm-sl-embed-li": { position: "relative", margin: "0.05em 0" },
  ".cm-sl-embed-marker": {
    display: "inline-block",
    minWidth: "1.1em",
    marginLeft: "-1.1em",
    color: "var(--scribe-accent, #0a66d0)",
  },
  ".cm-sl-embed-quote": {
    borderLeft: "2px solid var(--scribe-quote-bar, #d8d8de)",
    paddingLeft: "0.6em",
    color: "var(--scribe-muted, #9a9aa0)",
  },
  ".cm-sl-embed-pre": {
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    fontSize: "0.85em",
    backgroundColor: "var(--scribe-code-bg, rgba(0,0,0,0.05))",
    padding: "0.4em 0.6em",
    borderRadius: "4px",
    whiteSpace: "pre-wrap",
    margin: "0.2em 0",
  },
  ".cm-sl-embed-link": { color: "var(--scribe-accent, #0a66d0)" },
  ".cm-sl-embed-raw": { color: "var(--scribe-accent, #0a66d0)" },
});

// ── Block links ─────────────────────────────────────────────────────────────

const BLOCK_ID_RE = /(?:^|\s)\^([A-Za-z0-9][A-Za-z0-9_-]*)\s*$/;
const HEADING_RE = /^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/;
const LIST_ITEM_RE = /^\s*(?:[-*+]|\d+[.)])\s+/;

function newBlockId(docText) {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  for (let attempt = 0; attempt < 50; attempt++) {
    let id = "";
    for (let i = 0; i < 6; i++) id += alphabet[Math.floor(Math.random() * alphabet.length)];
    if (!new RegExp(`\\^${id}(?![A-Za-z0-9_-])`).test(docText)) return id;
  }
  return `b${Date.now().toString(36)}`;
}

/// The last line of the block holding `lineNumber`: the line itself for a
/// list item, else the end of the paragraph (next blank line / heading /
/// list item).
function blockEndLine(doc, lineNumber) {
  const line = doc.line(lineNumber);
  if (LIST_ITEM_RE.test(line.text)) return line;
  let end = line;
  while (end.number < doc.lines) {
    const next = doc.line(end.number + 1);
    if (!next.text.trim() || HEADING_RE.test(next.text) || LIST_ITEM_RE.test(next.text)) break;
    end = next;
  }
  return end;
}

registerCommand("copyBlockLink", (view, arg) => {
  const title = arg && typeof arg.title === "string" ? arg.title.trim() : "";
  const { state } = view;
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  if (!line.text.trim()) return false;
  if (inCode(state, line.from)) return false;
  const prefix = title || "";

  const heading = line.text.match(HEADING_RE);
  if (heading) {
    const text = heading[2].trim();
    if (!text) return false;
    postToNative({ type: "copyText", text: `[[${prefix}#${text}]]`, label: "Heading link copied" });
    return true;
  }

  const end = blockEndLine(state.doc, line.number);
  const existing = end.text.match(BLOCK_ID_RE);
  let id = existing ? existing[1] : null;
  if (!id) {
    id = newBlockId(state.doc.toString());
    const trimmedEnd = end.from + end.text.replace(/\s+$/, "").length;
    view.dispatch({ changes: { from: trimmedEnd, to: end.to, insert: ` ^${id}` } });
  }
  postToNative({ type: "copyText", text: `[[${prefix}#^${id}]]`, label: "Block link copied" });
  return true;
});

registerCommand("insertTemplate", (view, arg) => {
  if (!arg || typeof arg.text !== "string") return false;
  const text = arg.text;
  const sel = view.state.selection.main;
  const cursor = Number.isInteger(arg.cursor) && arg.cursor >= 0 && arg.cursor <= text.length ? arg.cursor : text.length;
  view.dispatch({
    changes: { from: sel.from, to: sel.to, insert: text },
    selection: { anchor: sel.from + cursor },
    scrollIntoView: true,
  });
  view.focus();
  return true;
});

registerCommand("setCursorOffset", (view, arg) => {
  if (!arg || !Number.isInteger(arg.offset)) return false;
  const length = view.state.doc.length;
  if (Number.isInteger(arg.docLength) && arg.docLength !== length) return false;
  const offset = Math.max(0, Math.min(length, arg.offset));
  view.dispatch({ selection: { anchor: offset }, scrollIntoView: true });
  view.focus();
  return true;
});

export function notePowerExtensions() {
  return [embedPlugin, embedTheme];
}
