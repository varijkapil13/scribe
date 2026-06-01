import SwiftUI

/// Single source of truth for what the main window's detail pane shows, with a
/// real Back/Forward history stack.
///
/// Replaces the scattered imperative `selection = …` mutations and
/// `NotificationCenter` navigation hops with one routed entry point, so every
/// jump is reversible (⌘[ / ⌘]), spatially legible, and reachable from the
/// command bar and the menu bar. `MainWindowView` binds `List(selection:)` to
/// `select(_:)` and routes every `onNavigate` closure through `navigate(to:)`.
@MainActor
@Observable
final class NavigationCoordinator {

    /// The destination currently shown in the detail pane.
    private(set) var current: MainSelection
    private var backStack: [MainSelection] = []
    private var forwardStack: [MainSelection] = []

    /// Cap history so a long session can't grow the stacks unbounded.
    private let maxDepth = 100

    init(current: MainSelection = .today) {
        self.current = current
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Navigate to `destination`, pushing the previous onto the back stack and
    /// clearing the forward stack (standard browser semantics). No-op when it
    /// is already current, so re-selecting a row doesn't pollute history.
    func navigate(to destination: MainSelection) {
        guard destination != current else { return }
        backStack.append(current)
        if backStack.count > maxDepth {
            backStack.removeFirst(backStack.count - maxDepth)
        }
        forwardStack.removeAll()
        current = destination
    }

    /// Binding-friendly setter for `List(selection:)`, which traffics in
    /// `MainSelection?`. A nil selection (e.g. clicking empty space) is ignored
    /// so the detail pane never goes blank.
    func select(_ destination: MainSelection?) {
        guard let destination else { return }
        navigate(to: destination)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }

    /// Replace the current destination WITHOUT recording history — for
    /// programmatic syncs that shouldn't create a spurious Back entry (e.g.
    /// reflecting a recording auto-flip the user didn't explicitly navigate to).
    func replaceCurrent(_ destination: MainSelection) {
        guard destination != current else { return }
        current = destination
    }
}
