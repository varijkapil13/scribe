// Document outline: after edits (debounced) JS posts the heading list to
// native as {type:"outline", headings:[{level, text, line}]} (line is 1-based)
// so the app can show a table of contents. Only posts when the list actually
// changes. Native can jump with the `scrollToLine` command (arg: 1-based line).
//
// Headings are found with a line scan (ATX `#` headings and setext `===` /
// `---` underlines), skipping fenced code blocks and front matter, so the
// result doesn't depend on how far the incremental parser has got.

import { EditorView, ViewPlugin } from "@codemirror/view";
import { EditorSelection } from "@codemirror/state";
import { postToNative, registerCommand } from "./bridge.js";

const DEBOUNCE_MS = 350;

/// Pure: extracts headings from a CodeMirror Text (or anything with
/// `lines` + `line(n).text`).
export function extractHeadings(doc) {
  const headings = [];
  let fence = null; // the opening fence marker while inside a code block
  let inFrontMatter = false;
  let prevText = null;
  let prevIsParagraph = false;
  for (let n = 1; n <= doc.lines; n++) {
    const text = doc.line(n).text;

    if (n === 1 && text.trim() === "---") {
      inFrontMatter = true;
      prevText = null;
      continue;
    }
    if (inFrontMatter) {
      if (text.trim() === "---" || text.trim() === "...") inFrontMatter = false;
      prevText = null;
      prevIsParagraph = false;
      continue;
    }

    const fenceMatch = text.match(/^ {0,3}(`{3,}|~{3,})/);
    if (fence) {
      if (fenceMatch && fenceMatch[1][0] === fence[0] && fenceMatch[1].length >= fence.length) {
        fence = null;
      }
      prevIsParagraph = false;
      continue;
    }
    if (fenceMatch) {
      fence = fenceMatch[1];
      prevIsParagraph = false;
      continue;
    }

    const atx = text.match(/^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$/);
    if (atx) {
      const content = (atx[2] || "").replace(/[ \t]+#+[ \t]*$/, "").replace(/^#+$/, "").trim();
      if (content) headings.push({ level: atx[1].length, text: stripInline(content), line: n });
      prevIsParagraph = false;
      prevText = text;
      continue;
    }

    const setext = text.match(/^ {0,3}(=+|-+)[ \t]*$/);
    if (setext && prevIsParagraph && prevText !== null) {
      headings.push({
        level: setext[1][0] === "=" ? 1 : 2,
        text: stripInline(prevText.trim()),
        line: n - 1,
      });
      prevIsParagraph = false;
      prevText = text;
      continue;
    }

    const trimmed = text.trim();
    // A plain paragraph line (setext candidate): not blank, not a list item,
    // quote, table row or indented code.
    prevIsParagraph =
      trimmed !== "" &&
      !/^ {0,3}([-*+]|\d+[.)])\s/.test(text) &&
      !/^ {0,3}>/.test(text) &&
      !/^\s*\|/.test(text) &&
      !/^( {4}|\t)/.test(text);
    prevText = text;
  }
  return headings;
}

/// Strips the most common inline markdown so the outline reads as plain text.
function stripInline(text) {
  return text
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g, "$2")
    .replace(/\[\[([^\]]+)\]\]/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__)(.+?)\1/g, "$2")
    .replace(/(\*|_)(.+?)\1/g, "$2")
    .replace(/~~(.+?)~~/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .trim();
}

let lastPostedKey = null;
let timer = null;

function postOutline(view) {
  const headings = extractHeadings(view.state.doc);
  const key = JSON.stringify(headings);
  if (key === lastPostedKey) return;
  lastPostedKey = key;
  postToNative({ type: "outline", headings });
}

function schedule(view) {
  if (timer !== null) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = null;
    postOutline(view);
  }, DEBOUNCE_MS);
}

const outlinePlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      schedule(view);
    }
    update(update) {
      if (update.docChanged) schedule(update.view);
    }
    destroy() {
      if (timer !== null) clearTimeout(timer);
      timer = null;
    }
  }
);

export function outlineExtensions() {
  return [outlinePlugin];
}

registerCommand("scrollToLine", (view, arg) => {
  const requested = Math.floor(Number(arg));
  if (!Number.isFinite(requested)) return false;
  const lineNumber = Math.min(Math.max(requested, 1), view.state.doc.lines);
  const line = view.state.doc.line(lineNumber);
  view.dispatch({
    selection: EditorSelection.cursor(line.from),
    effects: EditorView.scrollIntoView(line.from, { y: "start", yMargin: 24 }),
  });
  view.focus();
  return true;
});
