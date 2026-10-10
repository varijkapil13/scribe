import Foundation

// Portable (macOS + iOS): in-app writers outside the editor (Quick Capture,
// the Share-extension importer, App Intents) post this so an open editor
// picks up their change.

extension Notification.Name {
    /// Posted (main thread) after an in-app writer other than the note's
    /// editor rewrote a note file, e.g. Quick Capture appending to the daily
    /// note. `userInfo[NoteVaultChange.noteIdsKey]` is a `Set<String>` of
    /// note ids. An open editor reloads (or, with unsaved edits, keeps both
    /// versions) instead of overwriting the change with stale content.
    static let scribeNoteChangedInApp = Notification.Name("scribe.noteChangedInApp")
}
