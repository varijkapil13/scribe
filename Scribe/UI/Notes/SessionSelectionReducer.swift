// Scribe/UI/Notes/SessionSelectionReducer.swift
import Foundation

/// Pure decision logic for which session chip stays expanded in
/// `NoteDetailView` as the bound session list mutates.
///
/// Originally lived inside two `.onChange` closures in the view body where
/// it was untestable. The rules are subtle enough to warrant their own
/// tests:
///
///   1. When sessions arrive and the user hasn't explicitly collapsed the
///      auto-section, auto-select the most-recent.
///   2. When the user explicitly collapses (sets selection to nil while
///      sessions are non-empty), remember that choice and don't
///      auto-re-expand on the next sessions update.
///   3. If the currently-selected session vanishes from the list (e.g.
///      cascade-deleted), fall back to the new most-recent regardless of
///      the sticky-collapse flag — a stale selection would render nothing.
enum SessionSelectionReducer {

    /// Decision from `selectedSessionId`-changed: tells the view whether
    /// the user's nil-set should be treated as an explicit collapse.
    /// `hasSessions` matters because the same nil-set is "nothing to show"
    /// (sessions empty) versus "I'm dismissing this" (sessions present).
    static func userCollapsedFromTransition(
        newSelection: String?,
        hasSessions: Bool
    ) -> Bool? {
        if newSelection == nil && hasSessions { return true }   // explicit dismiss
        if newSelection != nil { return false }                 // re-expanded
        return nil                                              // no change
    }

    /// Decision from `vm.sessions`-changed: returns the selection the view
    /// should hold after applying the new sessions list.
    /// - `currentSelection`: the value of `selectedSessionId` before the
    ///   update.
    /// - `newSessions`: ordered as the VM emits them (newest first).
    /// - `userExplicitlyCollapsed`: sticky flag set by the helper above.
    static func selection(
        forNewSessions newSessions: [Session],
        currentSelection: String?,
        userExplicitlyCollapsed: Bool
    ) -> String? {
        let isStale = currentSelection.map { id in
            !newSessions.contains(where: { $0.id == id })
        } ?? false

        // Sticky collapse: respect the user's dismissal — unless the chip
        // they had selected was just removed, in which case the only valid
        // values are "the new most-recent" or nil-when-empty.
        if userExplicitlyCollapsed {
            return isStale ? newSessions.first?.id : currentSelection
        }

        // Default: auto-expand when sessions exist and we have no
        // selection, or recover from a stale selection.
        if currentSelection == nil {
            return newSessions.first?.id
        }
        if isStale {
            return newSessions.first?.id
        }
        return currentSelection
    }
}
