// Autocomplete for `[[wiki links]]` (note titles) and `#tags`.
//
// Data comes from native:
//   window.scribeSetCompletionData({titles: [...], tags: [...]})
// is pushed on load, and re-requested lazily: when a completion opens and the
// cached lists are older than REFRESH_MS, JS posts {type:"requestCompletionData"}
// and native answers with a fresh scribeSetCompletionData call (the completion
// source awaits that answer briefly, then falls back to the cached lists).
// Known titles pushed through scribeSetKnownTitles (wiki-link styling) also
// seed the title list, so completion works even before the first push.

import { autocompletion } from "@codemirror/autocomplete";
import { EditorView } from "@codemirror/view";
import { postToNative } from "./bridge.js";

const REFRESH_MS = 5000;
const REQUEST_TIMEOUT_MS = 250;

let titles = [];
let tags = [];
let lastUpdated = 0;
let waiters = [];

function cleanList(list) {
  if (!Array.isArray(list)) return [];
  const seen = new Set();
  const out = [];
  for (const item of list) {
    if (typeof item !== "string") continue;
    const value = item.trim();
    if (!value) continue;
    const key = value.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(value);
  }
  return out;
}

export function setCompletionTitles(list) {
  titles = cleanList(list);
}

window.scribeSetCompletionData = function (data) {
  if (data && typeof data === "object") {
    if (Array.isArray(data.titles)) titles = cleanList(data.titles);
    if (Array.isArray(data.tags)) {
      tags = cleanList(data.tags.map((tag) => (typeof tag === "string" ? tag.replace(/^#/, "") : tag)));
    }
  }
  lastUpdated = Date.now();
  const pending = waiters;
  waiters = [];
  for (const resolve of pending) resolve();
};

function refreshIfStale() {
  if (Date.now() - lastUpdated < REFRESH_MS) return Promise.resolve();
  return new Promise((resolve) => {
    waiters.push(resolve);
    postToNative({ type: "requestCompletionData" });
    setTimeout(resolve, REQUEST_TIMEOUT_MS);
  });
}

async function wikiLinkSource(context) {
  const match = context.matchBefore(/\[\[[^\[\]|\n]*$/);
  if (!match) return null;
  await refreshIfStale();
  if (context.aborted || !titles.length) return null;
  // If the closing brackets are already there (editing an existing link),
  // don't add a second pair — just step over them.
  const hasClosing = context.state.doc.sliceString(context.pos, context.pos + 2) === "]]";
  const options = titles.map((title) => ({
    label: title,
    type: "text",
    apply: (view, completion, from, to) => {
      const insert = hasClosing ? title : title + "]]";
      view.dispatch({
        changes: { from, to, insert },
        selection: { anchor: from + title.length + 2 },
        userEvent: "input.complete",
      });
    },
  }));
  // CodeMirror's fuzzy filter narrows/highlights while the typed text stays
  // a plain title fragment.
  return { from: match.from + 2, options, validFor: /^[^\[\]|\n]*$/ };
}

async function tagSource(context) {
  // `#tag` after whitespace / `(` / line start. A `# ` heading has a space
  // after the hash, so it never matches; a bare `#` at line start (a heading
  // being typed) doesn't open the menu unless completion was asked for.
  const match = context.matchBefore(/(?:^|[\s(])#[\p{L}\p{N}_\-\/]*$/u);
  if (!match) return null;
  const hashPos = match.from + match.text.lastIndexOf("#");
  const lineStart = context.state.doc.lineAt(context.pos).from;
  if (hashPos + 1 === context.pos && hashPos === lineStart && !context.explicit) return null;
  await refreshIfStale();
  if (context.aborted || !tags.length) return null;
  const options = tags.map((tag) => ({ label: tag, type: "keyword", detail: "tag" }));
  return { from: hashPos + 1, options, validFor: /^[\p{L}\p{N}_\-\/]*$/u };
}

const completionTheme = EditorView.baseTheme({
  ".cm-tooltip.cm-tooltip-autocomplete": {
    backgroundColor: "var(--scribe-menu-bg, #ffffff)",
    border: "1px solid var(--scribe-menu-border, rgba(0,0,0,0.12))",
    borderRadius: "8px",
    boxShadow: "0 8px 24px rgba(0,0,0,0.16)",
    padding: "4px",
    overflow: "hidden",
  },
  ".cm-tooltip.cm-tooltip-autocomplete > ul": {
    fontFamily: '-apple-system, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif',
    fontSize: "13px",
    maxHeight: "16em",
  },
  ".cm-tooltip.cm-tooltip-autocomplete > ul > li": {
    padding: "3px 10px",
    borderRadius: "5px",
    lineHeight: "1.5",
  },
  ".cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected]": {
    backgroundColor: "var(--scribe-menu-sel, rgba(10,102,208,0.12))",
    color: "inherit",
  },
  ".cm-completionDetail": {
    marginLeft: "8px",
    fontStyle: "normal",
    color: "var(--scribe-muted, #9a9aa0)",
  },
  ".cm-completionIcon": { display: "none" },
});

export function completionExtensions() {
  return [
    autocompletion({
      override: [wikiLinkSource, tagSource],
      icons: false,
      activateOnTyping: true,
      // Adds the stock completion keymap (↑/↓, Enter to accept, Esc to close)
      // at the highest precedence while the popup is open.
      defaultKeymap: true,
    }),
    completionTheme,
  ];
}
