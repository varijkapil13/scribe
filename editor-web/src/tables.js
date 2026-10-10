// GFM table editing helpers:
//   Tab        move to the next cell (wrapping to the next row; past the last
//              cell of the last row a new empty row is added)
//   Shift-Tab  move to the previous cell
//   Enter      at the end of a table row: add a new empty row below and put
//              the caret in its first cell. On an empty last row, Enter
//              removes that row and leaves the table (like list exiting).
// Cell contents are selected when moving so typing replaces them.
// Outside a table these keys fall through to the normal bindings.

import { keymap } from "@codemirror/view";
import { Prec, EditorSelection } from "@codemirror/state";

/// True when the line looks like a table row: starts with `|` (after
/// indentation) and has at least one more `|`.
export function isTableRow(text) {
  return /^\s*\|.*\|/.test(text);
}

/// True for the header delimiter row, e.g. `| --- | :---: |`.
export function isDelimiterRow(text) {
  return /^\s*\|(\s*:?-+:?\s*\|)+\s*$/.test(text);
}

/// Cell ranges (offsets within the line text) between unescaped pipes.
/// Returns [{from, to, contentFrom, contentTo}] where content excludes the
/// padding spaces.
export function cellRanges(text) {
  const pipes = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") {
      i++;
      continue;
    }
    if (text[i] === "|") pipes.push(i);
  }
  const cells = [];
  for (let k = 0; k + 1 < pipes.length; k++) {
    const from = pipes[k] + 1;
    const to = pipes[k + 1];
    let contentFrom = from;
    let contentTo = to;
    while (contentFrom < contentTo && text[contentFrom] === " ") contentFrom++;
    while (contentTo > contentFrom && text[contentTo - 1] === " ") contentTo--;
    cells.push({ from, to, contentFrom, contentTo });
  }
  return cells;
}

function cellIndexAt(cells, offset) {
  for (let i = 0; i < cells.length; i++) {
    if (offset >= cells[i].from && offset <= cells[i].to) return i;
  }
  return offset < (cells[0] ? cells[0].from : 0) ? 0 : cells.length - 1;
}

function selectCell(line, cell) {
  if (cell.contentFrom === cell.contentTo) {
    // Empty cell: caret one space in (after the leading pad) when possible.
    const pos = cell.from < cell.to ? cell.from + 1 : cell.from;
    return EditorSelection.cursor(line.from + Math.min(pos, cell.to));
  }
  return EditorSelection.range(line.from + cell.contentFrom, line.from + cell.contentTo);
}

function emptyRowFor(text) {
  const indent = text.match(/^\s*/)[0];
  const count = Math.max(cellRanges(text).length, 1);
  return indent + "|" + "   |".repeat(count);
}

function currentTableLine(state) {
  const sel = state.selection.main;
  if (state.selection.ranges.length > 1) return null;
  const line = state.doc.lineAt(sel.head);
  if (state.doc.lineAt(sel.anchor).number !== line.number) return null;
  if (!isTableRow(line.text)) return null;
  return line;
}

function moveToCell(view, forward) {
  const { state } = view;
  const line = currentTableLine(state);
  if (!line) return false;
  const cells = cellRanges(line.text);
  if (!cells.length) return false;
  const offset = state.selection.main.head - line.from;
  const index = cellIndexAt(cells, offset);

  if (forward && index + 1 < cells.length) {
    view.dispatch({ selection: selectCell(line, cells[index + 1]), scrollIntoView: true });
    return true;
  }
  if (!forward && index > 0) {
    view.dispatch({ selection: selectCell(line, cells[index - 1]), scrollIntoView: true });
    return true;
  }

  // Wrap to the adjacent row (skipping the delimiter row).
  let n = line.number + (forward ? 1 : -1);
  while (n >= 1 && n <= state.doc.lines) {
    const next = state.doc.line(n);
    if (!isTableRow(next.text)) break;
    if (!isDelimiterRow(next.text)) {
      const nextCells = cellRanges(next.text);
      if (nextCells.length) {
        const target = forward ? nextCells[0] : nextCells[nextCells.length - 1];
        view.dispatch({ selection: selectCell(next, target), scrollIntoView: true });
        return true;
      }
    }
    n += forward ? 1 : -1;
  }

  if (!forward) return true; // first cell of the table: stay put, swallow Tab
  // Past the last cell of the last row: append a new row.
  const row = emptyRowFor(line.text);
  const insertAt = line.to;
  const firstCellPos = insertAt + 1 + row.indexOf("|") + 2;
  view.dispatch({
    changes: { from: insertAt, insert: "\n" + row },
    selection: EditorSelection.cursor(firstCellPos),
    scrollIntoView: true,
    userEvent: "input",
  });
  return true;
}

function enterInTable(view) {
  const { state } = view;
  const line = currentTableLine(state);
  if (!line) return false;
  const sel = state.selection.main;
  if (!sel.empty) return false;
  // Only at the end of the row (ignoring trailing spaces).
  const rest = line.text.slice(sel.head - line.from);
  if (rest.trim() !== "") return false;

  const cells = cellRanges(line.text);
  const isEmptyRow =
    !isDelimiterRow(line.text) && cells.length > 0 && cells.every((c) => c.contentFrom === c.contentTo);
  const nextIsRow = line.number < state.doc.lines && isTableRow(state.doc.line(line.number + 1).text);

  if (isEmptyRow && !nextIsRow) {
    // Empty last row: drop it and leave the table on a blank line.
    view.dispatch({
      changes: { from: line.from, to: line.to, insert: "" },
      selection: EditorSelection.cursor(line.from),
      scrollIntoView: true,
      userEvent: "delete",
    });
    return true;
  }

  // On the header row, the new row goes after the delimiter row.
  let anchorLine = line;
  if (
    line.number < state.doc.lines &&
    isDelimiterRow(state.doc.line(line.number + 1).text)
  ) {
    anchorLine = state.doc.line(line.number + 1);
  }
  const row = emptyRowFor(line.text);
  const insertAt = anchorLine.to;
  const firstCellPos = insertAt + 1 + row.indexOf("|") + 2;
  view.dispatch({
    changes: { from: insertAt, insert: "\n" + row },
    selection: EditorSelection.cursor(firstCellPos),
    scrollIntoView: true,
    userEvent: "input",
  });
  return true;
}

export function tableExtensions() {
  // Highest precedence so it wins over lang-markdown's Enter (list
  // continuation) — but only when the caret is in a table row.
  return Prec.highest(
    keymap.of([
      { key: "Tab", run: (view) => moveToCell(view, true) },
      { key: "Shift-Tab", run: (view) => moveToCell(view, false) },
      { key: "Enter", run: enterInTable },
    ])
  );
}
