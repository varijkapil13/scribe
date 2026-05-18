import Foundation

/// Source-level undo buffer used by `MarkdownEditorView`.
///
/// The AST renderer rebuilds the editor's NSTextStorage from scratch on
/// every keystroke via `setAttributedString`. That invalidates AppKit's
/// position-based undo (a "remove char at N" replay finds the wrong
/// content after the formatting pass reveals markers / folds code
/// blocks), so we maintain our own stack of source-text snapshots and
/// apply them through the same path `editSource` uses for toolbar
/// actions.
///
/// Pure value-state, no view dependencies — the `Coordinator` calls
/// `record(...)` after each `applyFormatting` and `undo()` / `redo()`
/// from the Cmd-Z / Cmd-Shift-Z key handlers.
struct MarkdownUndoBuffer {

    struct Snapshot: Equatable {
        let source: String
        let selection: NSRange
    }

    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []

    /// Cap so a long-running session can't grow the stack without bound.
    /// 200 entries × ~4KB body ≈ 800KB worst-case which is fine for a
    /// notes app.
    var stackCap: Int = 200
    /// Coalesce typing within this gap into one undo step. Matches the
    /// feel of Apple Notes and TextEdit.
    var coalesceWindow: TimeInterval = 0.45

    /// The state we'd undo *to* — the most recent source seen.
    private(set) var currentSource: String = ""
    private(set) var currentSelection: NSRange = NSRange(location: 0, length: 0)
    private var lastSnapshotTime: Date = .distantPast
    /// True between the first and last keystroke of a typing burst.
    /// Cleared on hard boundary, undo/redo, or explicit
    /// `endTypingBurst()` (toolbar actions call this).
    private var withinTypingBurst: Bool = false
    /// True until the first user-driven change after a reset — used so
    /// pressing Cmd-Z on a freshly loaded note doesn't blank the editor.
    private var seeded: Bool = false

    // MARK: - Recording

    /// Records the latest (source, selection). Returns true if the call
    /// produced a new snapshot on the undo stack — useful for tests; the
    /// production Coordinator doesn't read the result.
    @discardableResult
    mutating func record(source: String, selection: NSRange, now: Date = Date()) -> Bool {
        if !seeded {
            // First call after a reset — seed the anchor without pushing
            // anything, so the FIRST undo doesn't roll back to empty.
            currentSource = source
            currentSelection = selection
            lastSnapshotTime = now
            seeded = true
            return false
        }
        if currentSource == source {
            currentSelection = selection
            return false
        }

        let gap = now.timeIntervalSince(lastSnapshotTime)
        // Hard boundary criteria: a newline added (line commits), or a
        // delta larger than one character (paste / non-typing edits).
        let delta = abs(source.count - currentSource.count)
        let crossedNewline = source.count > currentSource.count && source.last == "\n"
        let hardBoundary = crossedNewline || delta > 1
        let shouldPush = !withinTypingBurst
            || hardBoundary
            || gap > coalesceWindow

        var pushed = false
        if shouldPush {
            undoStack.append(Snapshot(source: currentSource, selection: currentSelection))
            if undoStack.count > stackCap {
                undoStack.removeFirst(undoStack.count - stackCap)
            }
            redoStack.removeAll()
            // Stay in a burst only for typing-shaped changes — paste etc.
            // commits and starts fresh.
            withinTypingBurst = !hardBoundary
            pushed = true
        }

        currentSource = source
        currentSelection = selection
        lastSnapshotTime = now
        return pushed
    }

    /// Called by `editSource` / toolbar actions so a deliberate edit
    /// always starts a new undo step instead of merging into a typing
    /// burst.
    mutating func endTypingBurst() {
        withinTypingBurst = false
    }

    // MARK: - Undo / Redo

    /// Pops the most recent snapshot and returns it; pushes the current
    /// state to the redo stack so it can be restored.
    mutating func popUndo() -> Snapshot? {
        guard let snap = undoStack.popLast() else { return nil }
        redoStack.append(Snapshot(source: currentSource, selection: currentSelection))
        currentSource = snap.source
        currentSelection = snap.selection
        withinTypingBurst = false
        return snap
    }

    mutating func popRedo() -> Snapshot? {
        guard let snap = redoStack.popLast() else { return nil }
        undoStack.append(Snapshot(source: currentSource, selection: currentSelection))
        currentSource = snap.source
        currentSelection = snap.selection
        withinTypingBurst = false
        return snap
    }

    // MARK: - Lifecycle

    /// Wipes both stacks. Called by the Coordinator when the editor
    /// switches to a different note.
    mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        currentSource = ""
        currentSelection = NSRange(location: 0, length: 0)
        lastSnapshotTime = .distantPast
        withinTypingBurst = false
        seeded = false
    }
}
