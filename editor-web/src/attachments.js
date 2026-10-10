// Image / file paste & drop.
//
// Pasted or dropped files are intercepted, read as base64, and posted to native:
//   {type:"attachment", id, filename, mime, data}
// Native saves the bytes into the note's attachments folder (unique, sanitized
// name, 50 MB cap) and answers with one of:
//   window.scribeAttachmentSaved(id, {path, name, isImage})
//   window.scribeAttachmentFailed(id, message)
// On success JS inserts `![name](path)` (images) or `[name](path)` (other
// files) at the paste/drop position — tracked through later edits with a
// StateField, so typing while the save is in flight doesn't misplace it.
// Native can also insert at the caret directly (e.g. Continuity Camera):
//   window.scribeInsertAttachment({path, name, isImage})

import { EditorView } from "@codemirror/view";
import { StateEffect, StateField } from "@codemirror/state";
import { postToNative } from "./bridge.js";

const MAX_BYTES = 50 * 1024 * 1024;

let editorView = null;
let nextId = 1;

const addPending = StateEffect.define();
const removePending = StateEffect.define();
/// Drops every in-flight paste/drop position. editor.js adds it to the
/// whole-document replacement in `scribeSetDoc` (e.g. another note loaded into
/// this editor), so a save that finishes afterwards is never inserted into a
/// different document at a meaningless position.
export const clearPendingAttachments = StateEffect.define();
// Marks the transaction that inserts a finished attachment, so other pending
// files at the same spot land after it (keeping multi-file order).
const insertingAttachment = StateEffect.define();

// id -> doc position, mapped through every change. Text typed exactly at a
// pending spot goes after it (assoc -1 keeps the spot before the typing);
// attachment inserts push same-spot pending files after themselves.
const pendingField = StateField.define({
  create() {
    return new Map();
  },
  update(value, tr) {
    let next = value;
    if (tr.docChanged && value.size) {
      const assoc = tr.effects.some((e) => e.is(insertingAttachment)) ? 1 : -1;
      next = new Map();
      for (const [id, pos] of value) next.set(id, tr.changes.mapPos(pos, assoc));
    }
    for (const e of tr.effects) {
      if (e.is(addPending)) {
        if (next === value) next = new Map(value);
        next.set(e.value.id, e.value.pos);
      } else if (e.is(removePending)) {
        if (next === value) next = new Map(value);
        next.delete(e.value);
      } else if (e.is(clearPendingAttachments)) {
        next = new Map();
      }
    }
    return next;
  },
});

/// Markdown link text for a saved attachment. Paths are sanitized natively
/// (no spaces/parens), but wrap in <> defensively if they contain any.
export function markdownForAttachment(info) {
  const path = String(info.path || "");
  const label = String(info.name || "").replace(/[\[\]\n]/g, " ").trim();
  const target = /[\s()<>]/.test(path) ? `<${path}>` : path;
  return info.isImage ? `![${label}](${target})` : `[${label || path}](${target})`;
}

// Inserts `text` at `pos`. The caret only moves to after the insert when it
// sat right at `pos` (a save that finishes while the user is typing elsewhere
// must not yank the caret).
function insertAt(view, pos, text) {
  const doc = view.state.doc;
  const at = Math.min(Math.max(pos, 0), doc.length);
  // Put block-ish images on their own when dropped mid-word.
  const before = at > 0 ? doc.sliceString(at - 1, at) : "";
  const prefix = before && !/\s/.test(before) ? " " : "";
  const insert = prefix + text;
  const main = view.state.selection.main;
  const caretAtSpot = main.empty && main.head === at;
  view.dispatch({
    changes: { from: at, insert },
    selection: caretAtSpot ? { anchor: at + insert.length } : undefined,
    effects: insertingAttachment.of(null),
    scrollIntoView: true,
    userEvent: "input.paste",
  });
}

function readAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error("read failed"));
    reader.onload = () => {
      const result = String(reader.result || "");
      const comma = result.indexOf(",");
      resolve(comma >= 0 ? result.slice(comma + 1) : "");
    };
    reader.readAsDataURL(file);
  });
}

function fileName(file, index) {
  if (file.name) return file.name;
  const ext = (file.type.split("/")[1] || "bin").replace(/[^a-z0-9]/gi, "");
  return `Pasted ${index + 1}.${ext || "bin"}`;
}

async function sendFiles(view, files, pos) {
  // Insert in order: each file gets its own pending position; later files are
  // inserted after earlier ones via the shared mapped anchor.
  let index = 0;
  for (const file of files) {
    const id = `a${nextId++}`;
    if (file.size > MAX_BYTES) {
      postToNative({ type: "attachmentRejected", filename: fileName(file, index), reason: "tooLarge" });
      index++;
      continue;
    }
    view.dispatch({ effects: addPending.of({ id, pos }) });
    try {
      const data = await readAsBase64(file);
      postToNative({
        type: "attachment",
        id,
        filename: fileName(file, index),
        mime: file.type || "",
        data,
      });
    } catch (e) {
      view.dispatch({ effects: removePending.of(id) });
    }
    index++;
  }
}

function filesFrom(list) {
  const files = [];
  if (!list) return files;
  for (let i = 0; i < list.length; i++) {
    const f = list[i];
    if (f) files.push(f);
  }
  return files;
}

const handlers = EditorView.domEventHandlers({
  paste(event, view) {
    const files = filesFrom(event.clipboardData && event.clipboardData.files);
    if (!files.length) return false;
    // Rich text copied from a browser often carries an image *and* text; only
    // take over when there's no plain text to paste, or the text is just the
    // file name(s) (a file copied in Finder).
    const text = (event.clipboardData.getData("text/plain") || "").trim();
    if (text && !files.some((f) => f.name && text.includes(f.name))) return false;
    event.preventDefault();
    sendFiles(view, files, view.state.selection.main.head);
    return true;
  },
  dragover(event) {
    if (event.dataTransfer && Array.from(event.dataTransfer.types || []).includes("Files")) {
      event.preventDefault();
    }
    return false;
  },
  drop(event, view) {
    const files = filesFrom(event.dataTransfer && event.dataTransfer.files);
    if (!files.length) return false;
    event.preventDefault();
    const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
    sendFiles(view, files, pos == null ? view.state.selection.main.head : pos);
    return true;
  },
});

export function attachmentExtensions() {
  return [pendingField, handlers];
}

function hasFiles(event) {
  return !!(event.dataTransfer && Array.from(event.dataTransfer.types || []).includes("Files"));
}

let documentDropGuardInstalled = false;

export function setAttachmentView(view) {
  editorView = view;
  if (documentDropGuardInstalled) return;
  documentDropGuardInstalled = true;
  // Files dropped outside the text (the fold gutter, page padding, the search
  // panel) would otherwise get WebKit's default drop handling: navigating the
  // web view to the file and unloading the editor. Swallow those drops and
  // insert the files at the caret instead. Drops on the text itself are
  // handled (and default-prevented) by the CodeMirror handler above first.
  document.addEventListener("dragover", (event) => {
    if (hasFiles(event)) event.preventDefault();
  });
  document.addEventListener("drop", (event) => {
    if (event.defaultPrevented || !hasFiles(event)) return;
    event.preventDefault();
    const files = filesFrom(event.dataTransfer.files);
    if (files.length && editorView) {
      sendFiles(editorView, files, editorView.state.selection.main.head);
    }
  });
}

window.scribeAttachmentSaved = function (id, info) {
  const view = editorView;
  if (!view || !info) return;
  const pending = view.state.field(pendingField, false);
  // No pending entry: the document was replaced (another note loaded) while
  // the file was being saved. The file stays in the attachments folder but
  // the link is not inserted into an unrelated document.
  if (!pending || !pending.has(id)) return;
  const pos = pending.get(id);
  view.dispatch({ effects: removePending.of(id) });
  insertAt(view, pos, markdownForAttachment(info));
};

window.scribeAttachmentFailed = function (id) {
  const view = editorView;
  if (!view) return;
  view.dispatch({ effects: removePending.of(id) });
};

window.scribeInsertAttachment = function (info) {
  const view = editorView;
  if (!view || !info) return;
  insertAt(view, view.state.selection.main.head, markdownForAttachment(info));
  view.focus();
};
