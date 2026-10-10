// Native bridge plumbing shared by the editor modules.
//
// JS -> native: postToNative({type, ...}) posts to the `scribe` WKScriptMessage
// handler (no-op outside the WKWebView host, e.g. a plain browser preview).
//
// native -> JS commands: native calls `window.scribeCommand(name, arg)`; each
// feature module registers the command names it understands with
// `registerCommand(name, (view, arg) => boolean)`. Unknown names are ignored
// (returns false) so an older bundle never throws on a newer native caller.
// Command names currently registered (see the modules):
//   find / replace / findNext / findPrevious / selectAllMatches / replaceAll /
//   closeFind                                          (search.js)
//   fold / unfold / foldAll / unfoldAll / toggleFold   (folding.js)
//   scrollToLine (arg: 1-based line number)            (outline.js)
//   embedContent / invalidateEmbeds / copyBlockLink /
//   insertTemplate / setCursorOffset                   (notepower.js)

export function postToNative(message) {
  try {
    window.webkit.messageHandlers.scribe.postMessage(message);
  } catch (e) {
    // Running outside the WKWebView host. Swallow — the editor still works,
    // it just has no native peer.
  }
}

const commands = new Map();
let commandView = null;

/// Registers a native-callable command. `run(view, arg)` should return true
/// when it handled the command.
export function registerCommand(name, run) {
  commands.set(name, run);
}

/// Called once by editor.js after the EditorView is constructed.
export function setCommandView(view) {
  commandView = view;
}

window.scribeCommand = function (name, arg) {
  const run = commands.get(name);
  if (!run || !commandView) return false;
  try {
    return run(commandView, arg === undefined ? null : arg) === true;
  } catch (e) {
    return false;
  }
};
