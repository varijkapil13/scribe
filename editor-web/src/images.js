// Live-preview rendering of markdown images `![alt](path)`.
//
// Off the active line the image syntax is replaced by the image itself; on
// the active line the raw markdown stays editable. Only LOCAL attachments are
// rendered: a vault-relative path such as `attachments/<noteId>/photo.png` is
// loaded from `scribe-asset://vault/<path>`, which WebMarkdownEditor's
// EditorAssetSchemeHandler serves from the notes vault (restricted to the
// vault's attachments/ folder and to image types). Remote http(s) images are
// NOT fetched (privacy: opening a note must not contact third-party servers),
// and absolute / file: paths are never resolved — those stay as raw text.

import { Decoration, EditorView, ViewPlugin, WidgetType } from "@codemirror/view";
import { RangeSetBuilder } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";

const VAULT_BASE = "scribe-asset://vault/";

/// Maps a markdown image target to a loadable URL, or null when it must not
/// be rendered. Pure (exported for reuse).
export function imageURLForTarget(raw) {
  let target = String(raw || "").trim();
  if (target.startsWith("<") && target.endsWith(">")) target = target.slice(1, -1).trim();
  // Drop an optional title: ![](path "title")
  const titled = target.match(/^(\S+)\s+["'(].*["')]$/);
  if (titled) target = titled[1];
  if (!target) return null;
  if (/^data:image\//i.test(target)) return target;
  if (/^[a-z][a-z0-9+.-]*:/i.test(target)) return null; // http:, file:, …
  if (target.startsWith("/") || target.startsWith("~")) return null;
  while (target.startsWith("./")) target = target.slice(2);
  if (target.split("/").includes("..")) return null;
  const encoded = /%[0-9a-f]{2}/i.test(target) ? target : encodeURI(target);
  return VAULT_BASE + encoded;
}

class ImageWidget extends WidgetType {
  constructor(url, alt) {
    super();
    this.url = url;
    this.alt = alt;
  }
  eq(other) {
    return other.url === this.url && other.alt === this.alt;
  }
  toDOM() {
    const wrap = document.createElement("span");
    wrap.className = "cm-sl-image";
    const img = document.createElement("img");
    img.src = this.url;
    img.alt = this.alt;
    img.title = this.alt;
    img.draggable = false;
    img.addEventListener("error", () => {
      wrap.classList.add("cm-sl-image-broken");
      wrap.textContent = this.alt ? `\u{1F5BC} ${this.alt}` : "\u{1F5BC} image not found";
    });
    wrap.appendChild(img);
    return wrap;
  }
  ignoreEvent() {
    // Let clicks through so CodeMirror moves the caret onto the line (which
    // reveals the raw markdown for editing).
    return false;
  }
}

function buildImageDecorations(view) {
  const { state } = view;
  const activeLines = new Set();
  for (const range of state.selection.ranges) {
    const a = state.doc.lineAt(range.from).number;
    const b = state.doc.lineAt(range.to).number;
    for (let n = a; n <= b; n++) activeLines.add(n);
  }
  const found = [];
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        if (node.name !== "Image") return;
        const text = state.doc.sliceString(node.from, node.to);
        const m = text.match(/^!\[([^\]]*)\]\(([\s\S]*)\)$/);
        if (!m) return false;
        const startLine = state.doc.lineAt(node.from).number;
        const endLine = state.doc.lineAt(node.to).number;
        if (startLine !== endLine || activeLines.has(startLine)) return false;
        const url = imageURLForTarget(m[2]);
        if (!url) return false;
        found.push({ from: node.from, to: node.to, url, alt: m[1] });
        return false;
      },
    });
  }
  found.sort((a, b) => a.from - b.from);
  const builder = new RangeSetBuilder();
  let lastTo = -1;
  for (const f of found) {
    if (f.from < lastTo) continue;
    builder.add(f.from, f.to, Decoration.replace({ widget: new ImageWidget(f.url, f.alt) }));
    lastTo = f.to;
  }
  return builder.finish();
}

const imagePlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = buildImageDecorations(view);
    }
    update(update) {
      if (update.docChanged || update.selectionSet || update.viewportChanged) {
        this.decorations = buildImageDecorations(update.view);
      }
    }
  },
  { decorations: (v) => v.decorations }
);

const imageTheme = EditorView.baseTheme({
  ".cm-sl-image": { display: "inline-block", maxWidth: "100%", verticalAlign: "bottom" },
  ".cm-sl-image img": {
    display: "block",
    maxWidth: "100%",
    maxHeight: "70vh",
    borderRadius: "6px",
    margin: "4px 0",
  },
  ".cm-sl-image-broken": {
    color: "var(--scribe-muted, #9a9aa0)",
    fontStyle: "italic",
  },
});

export function imageExtensions() {
  return [imagePlugin, imageTheme];
}
