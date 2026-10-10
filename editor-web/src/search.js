// Find & replace: @codemirror/search with a prose-styled panel at the top of
// the editor, the standard search keymap (⌘F, ⌘G, ⇧⌘G, ⌥⌘F …), match
// highlighting, and native-callable commands so the app's Find menu can drive
// it through `window.scribeCommand(name, arg)`:
//   find          open the panel (arg: optional query string to prefill)
//   replace       open the panel focused on the Replace field
//                 (arg: optional {search, replace} object)
//   findNext / findPrevious / selectAllMatches / replaceAll / closeFind

import { EditorView, keymap } from "@codemirror/view";
import { Prec } from "@codemirror/state";
import {
  search,
  searchKeymap,
  openSearchPanel,
  closeSearchPanel,
  findNext,
  findPrevious,
  selectMatches,
  replaceAll,
  getSearchQuery,
  setSearchQuery,
  SearchQuery,
  highlightSelectionMatches,
} from "@codemirror/search";
import { registerCommand } from "./bridge.js";

const searchTheme = EditorView.baseTheme({
  ".cm-panels": {
    backgroundColor: "var(--scribe-menu-bg, #ffffff)",
    color: "inherit",
  },
  ".cm-panels.cm-panels-top": {
    borderBottom: "1px solid var(--scribe-menu-border, rgba(0,0,0,0.12))",
  },
  ".cm-panel.cm-search": {
    padding: "8px 36px 8px 14px",
    position: "relative",
    fontFamily: '-apple-system, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif',
    fontSize: "12.5px",
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: "6px",
  },
  // The stock panel separates the Find and Replace rows with a <br>; make it a
  // full-width flex item so the rows still wrap.
  ".cm-panel.cm-search br": { display: "block", flexBasis: "100%", height: "0" },
  ".cm-panel.cm-search input.cm-textfield": {
    font: "inherit",
    fontSize: "13px",
    padding: "4px 8px",
    minWidth: "180px",
    borderRadius: "6px",
    border: "1px solid var(--scribe-menu-border, rgba(0,0,0,0.12))",
    background: "var(--scribe-panel-bg, rgba(0,0,0,0.035))",
    color: "inherit",
    outline: "none",
    margin: 0,
  },
  ".cm-panel.cm-search input.cm-textfield:focus": {
    borderColor: "var(--scribe-accent, #0a66d0)",
    boxShadow: "0 0 0 3px var(--scribe-accent-soft, rgba(10,102,208,0.10))",
  },
  ".cm-panel.cm-search button.cm-button": {
    font: "inherit",
    padding: "3px 10px",
    borderRadius: "6px",
    border: "1px solid var(--scribe-menu-border, rgba(0,0,0,0.12))",
    backgroundImage: "none",
    backgroundColor: "var(--scribe-panel-bg, rgba(0,0,0,0.035))",
    color: "inherit",
    cursor: "default",
    margin: 0,
  },
  ".cm-panel.cm-search button.cm-button:active": {
    backgroundColor: "var(--scribe-menu-sel, rgba(10,102,208,0.12))",
  },
  ".cm-panel.cm-search label": {
    display: "inline-flex",
    alignItems: "center",
    gap: "3px",
    color: "var(--scribe-muted, #9a9aa0)",
    margin: 0,
  },
  ".cm-panel.cm-search button[name=close]": {
    position: "absolute",
    top: "6px",
    right: "10px",
    border: "none",
    background: "transparent",
    fontSize: "16px",
    color: "var(--scribe-muted, #9a9aa0)",
    cursor: "default",
  },
  ".cm-searchMatch": {
    backgroundColor: "rgba(255, 204, 0, 0.32)",
    borderRadius: "2px",
  },
  ".cm-searchMatch.cm-searchMatch-selected": {
    backgroundColor: "rgba(255, 149, 0, 0.55)",
  },
  ".cm-selectionMatch": {
    backgroundColor: "var(--scribe-accent-soft, rgba(10,102,208,0.10))",
  },
});

export function searchExtensions() {
  return [
    search({ top: true }),
    highlightSelectionMatches(),
    // Above the default keymap so ⌘F / ⌘G reach the search commands.
    Prec.high(keymap.of(searchKeymap)),
    searchTheme,
  ];
}

function prefill(view, spec) {
  const current = getSearchQuery(view.state);
  const query = new SearchQuery({
    search: typeof spec.search === "string" ? spec.search : current.search,
    replace: typeof spec.replace === "string" ? spec.replace : current.replace,
    caseSensitive: current.caseSensitive,
    regexp: current.regexp,
    wholeWord: current.wholeWord,
    literal: current.literal,
  });
  view.dispatch({ effects: setSearchQuery.of(query) });
}

function focusPanelField(view, name) {
  const field = view.dom.querySelector(`.cm-search input[name=${name}]`);
  if (field) {
    field.focus();
    field.select();
  }
}

registerCommand("find", (view, arg) => {
  openSearchPanel(view);
  if (typeof arg === "string") prefill(view, { search: arg });
  focusPanelField(view, "search");
  return true;
});

registerCommand("replace", (view, arg) => {
  openSearchPanel(view);
  if (arg && typeof arg === "object") prefill(view, arg);
  // Focus Replace when there's already something to find; otherwise start in
  // the Find field so the user can type the query first.
  const hasQuery = getSearchQuery(view.state).search !== "";
  focusPanelField(view, hasQuery ? "replace" : "search");
  return true;
});

registerCommand("findNext", (view) => findNext(view));
registerCommand("findPrevious", (view) => findPrevious(view));
registerCommand("selectAllMatches", (view) => selectMatches(view));
registerCommand("replaceAll", (view) => replaceAll(view));
registerCommand("closeFind", (view) => closeSearchPanel(view));
