// Native editor commands (menu bar → CodeMirror).
//
// The macOS app's Format / Find menus send string commands to the focused
// editor through ONE entry point:
//
//   window.scribeCommand(name, arg) -> boolean (true when handled)
//
// (Swift side: Scribe/UI/Notes/EditorCommandBridge.swift.) Handlers live in a
// shared registry, `window.scribeCommandHandlers`, so other modules can add
// commands (e.g. "find" / "replace" / "findNext" / "findPrevious") without
// touching this file: `registerScribeCommands({ find: () => … })`. Unknown
// names return false and are otherwise ignored.
//
// Format commands implemented here (all toggle, all multi-selection aware):
//   bold, italic, strikethrough, code, link,
//   heading (arg: 0 = paragraph, 1–6), bulletList, orderedList, checklist,
//   blockquote

import { EditorSelection } from "@codemirror/state";

/** Adds `handlers` (name → fn(arg, view)) to the shared registry and makes
 *  sure the dispatcher exists. Safe to call more than once. */
export function registerScribeCommands(view, handlers) {
  const registry = (window.scribeCommandHandlers = window.scribeCommandHandlers || {});
  for (const name of Object.keys(handlers)) {
    const fn = handlers[name];
    registry[name] = (arg) => fn(arg, view);
  }
  if (typeof window.scribeCommand !== "function") {
    window.scribeCommand = function (name, arg) {
      const handler = (window.scribeCommandHandlers || {})[name];
      if (typeof handler !== "function") return false;
      try {
        return handler(arg) !== false;
      } catch (e) {
        return false;
      }
    };
  }
}

// ── Inline marks ────────────────────────────────────────────────────────────

/** Wraps (or unwraps) every selection range in `marker`. An empty range
 *  inserts a marker pair with the caret between them. */
function toggleInlineMark(view, marker) {
  const len = marker.length;
  const doc = view.state.doc;
  const tr = view.state.changeByRange((range) => {
    const before = doc.sliceString(Math.max(0, range.from - len), range.from);
    const after = doc.sliceString(range.to, Math.min(doc.length, range.to + len));
    if (before === marker && after === marker) {
      // Already wrapped just outside the selection → unwrap.
      return {
        changes: [
          { from: range.from - len, to: range.from, insert: "" },
          { from: range.to, to: range.to + len, insert: "" },
        ],
        range: EditorSelection.range(range.from - len, range.to - len),
      };
    }
    const text = doc.sliceString(range.from, range.to);
    if (text.length >= 2 * len && text.startsWith(marker) && text.endsWith(marker)) {
      // The selection itself includes the markers → unwrap inside it.
      return {
        changes: [
          { from: range.from, to: range.from + len, insert: "" },
          { from: range.to - len, to: range.to, insert: "" },
        ],
        range: EditorSelection.range(range.from, range.to - 2 * len),
      };
    }
    return {
      changes: [
        { from: range.from, insert: marker },
        { from: range.to, insert: marker },
      ],
      range: EditorSelection.range(range.from + len, range.to + len),
    };
  });
  view.dispatch(view.state.update(tr, { scrollIntoView: true, userEvent: "input.format" }));
  view.focus();
  return true;
}

/** `[selection](url)` — caret lands in the URL slot (or the text slot when
 *  nothing was selected). */
function insertLink(view) {
  const doc = view.state.doc;
  const tr = view.state.changeByRange((range) => {
    const text = doc.sliceString(range.from, range.to);
    const insert = `[${text}]()`;
    const caret = text.length > 0 ? range.from + text.length + 3 : range.from + 1;
    return {
      changes: { from: range.from, to: range.to, insert },
      range: EditorSelection.cursor(caret),
    };
  });
  view.dispatch(view.state.update(tr, { scrollIntoView: true, userEvent: "input.format" }));
  view.focus();
  return true;
}

// ── Line prefixes ───────────────────────────────────────────────────────────

/** Distinct line numbers touched by the selection, in document order. */
function selectedLineNumbers(state) {
  const seen = new Set();
  const out = [];
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.to).number;
    for (let n = first; n <= last; n++) {
      if (!seen.has(n)) {
        seen.add(n);
        out.push(n);
      }
    }
  }
  return out.sort((a, b) => a - b);
}

const HEADING_RE = /^(#{1,6})[ \t]+/;
const LIST_RE = /^([ \t]*)(?:[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d+[.)][ \t]+)/;
const QUOTE_RE = /^>[ \t]?/;

/** Applies `transform(lineText, index) -> newText | null` to each selected
 *  line (null = leave unchanged). */
function rewriteLines(view, transform) {
  const state = view.state;
  const changes = [];
  selectedLineNumbers(state).forEach((n, index) => {
    const line = state.doc.line(n);
    const next = transform(line.text, index);
    if (next !== null && next !== line.text) {
      changes.push({ from: line.from, to: line.to, insert: next });
    }
  });
  if (changes.length > 0) {
    view.dispatch({ changes, scrollIntoView: true, userEvent: "input.format" });
  }
  view.focus();
  return true;
}

function setHeading(view, level) {
  const target = Number(level) || 0;
  const lines = selectedLineNumbers(view.state).map((n) => view.state.doc.line(n).text);
  // Toggle: when every line is already at this level, drop back to paragraph.
  const allAtLevel =
    target > 0 &&
    lines.filter((text) => text.trim().length > 0).length > 0 &&
    lines.filter((text) => text.trim().length > 0).every((text) => {
      const m = HEADING_RE.exec(text);
      return m !== null && m[1].length === target;
    });
  return rewriteLines(view, (text) => {
    const stripped = text.replace(HEADING_RE, "");
    if (target <= 0 || allAtLevel) return stripped;
    if (stripped.trim().length === 0) return null; // never head a blank line
    return `${"#".repeat(Math.min(6, target))} ${stripped}`;
  });
}

/** Toggles a list/quote prefix. `kind`: "bullet" | "ordered" | "check" | "quote". */
function toggleLinePrefix(view, kind) {
  const state = view.state;
  const texts = selectedLineNumbers(state).map((n) => state.doc.line(n).text);
  const nonBlank = texts.filter((text) => text.trim().length > 0);
  const has = (text) => {
    if (kind === "quote") return QUOTE_RE.test(text);
    const m = LIST_RE.exec(text);
    if (!m) return false;
    const marker = text.slice(m[1].length, m[0].length).trim();
    if (kind === "check") return /\[[ xX]\]$/.test(marker);
    if (kind === "ordered") return /^\d+[.)]$/.test(marker);
    return /^[-*+]$/.test(marker);
  };
  const remove = nonBlank.length > 0 && nonBlank.every(has);
  let ordinal = 0;
  return rewriteLines(view, (text) => {
    if (text.trim().length === 0) return null;
    if (kind === "quote") {
      return remove ? text.replace(QUOTE_RE, "") : `> ${text}`;
    }
    const m = LIST_RE.exec(text);
    const indent = m ? m[1] : /^[ \t]*/.exec(text)[0];
    const content = m ? text.slice(m[0].length) : text.slice(indent.length);
    if (remove) return indent + content;
    ordinal += 1;
    const prefix = kind === "ordered" ? `${ordinal}. ` : kind === "check" ? "- [ ] " : "- ";
    return indent + prefix + content;
  });
}

/** Registers the format commands for `view`. */
export function installFormatCommands(view) {
  registerScribeCommands(view, {
    bold: (_arg, v) => toggleInlineMark(v, "**"),
    italic: (_arg, v) => toggleInlineMark(v, "*"),
    strikethrough: (_arg, v) => toggleInlineMark(v, "~~"),
    code: (_arg, v) => toggleInlineMark(v, "`"),
    link: (_arg, v) => insertLink(v),
    heading: (arg, v) => setHeading(v, arg),
    bulletList: (_arg, v) => toggleLinePrefix(v, "bullet"),
    orderedList: (_arg, v) => toggleLinePrefix(v, "ordered"),
    checklist: (_arg, v) => toggleLinePrefix(v, "check"),
    blockquote: (_arg, v) => toggleLinePrefix(v, "quote"),
  });
}
