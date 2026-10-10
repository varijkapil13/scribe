import Foundation

/// Registers reversible model actions (task completion, deletes, field
/// changes, note deletes) with a window's `UndoManager`, so Edit › Undo / Redo
/// (⌘Z / ⇧⌘Z) and their menu titles ("Undo Delete Task") just work.
///
/// Call `register` right after performing an action, passing closures that
/// revert it (`undo`) and re-apply it (`redo`). Undoing runs `undo` and
/// registers `redo` on the redo stack; redoing runs `redo` and registers
/// `undo` again — so the pair can be cycled indefinitely. The closures must
/// talk to the stores directly (never through code that itself registers
/// undo) or a step would register twice.
@MainActor
enum UndoableActions {
    typealias Step = () -> Void

    static func register(on undoManager: UndoManager?,
                         actionName: String,
                         undo: @escaping Step,
                         redo: @escaping Step) {
        guard let undoManager else { return }
        ScribeUndoStep(undoManager: undoManager,
                       actionName: actionName,
                       perform: undo,
                       inverse: redo).register()
    }
}

/// One entry on an undo/redo stack. It is the undo target and is retained by
/// its handler, so it lives exactly as long as the stack entry.
///
/// `@unchecked Sendable`: the undo handler API may require a Sendable target,
/// but every member is only touched on the main actor (registration happens
/// from `@MainActor` code and AppKit performs undo on the main thread).
final class ScribeUndoStep: @unchecked Sendable {
    private weak var undoManager: UndoManager?
    private let actionName: String
    private let perform: UndoableActions.Step
    private let inverse: UndoableActions.Step

    init(undoManager: UndoManager,
         actionName: String,
         perform: @escaping UndoableActions.Step,
         inverse: @escaping UndoableActions.Step) {
        self.undoManager = undoManager
        self.actionName = actionName
        self.perform = perform
        self.inverse = inverse
    }

    @MainActor
    func register() {
        guard let undoManager else { return }
        // The closure form of registerUndo; if its handler signature changes
        // in a future SDK, this call is the only place to adapt.
        // The handler captures `self` strongly: the undo manager isn't
        // guaranteed to retain its target.
        undoManager.registerUndo(withTarget: self) { [self] _ in
            MainActor.assumeIsolated { self.run() }
        }
        undoManager.setActionName(actionName)
    }

    @MainActor
    private func run() {
        perform()
        guard let undoManager else { return }
        ScribeUndoStep(undoManager: undoManager,
                       actionName: actionName,
                       perform: inverse,
                       inverse: perform).register()
    }
}
