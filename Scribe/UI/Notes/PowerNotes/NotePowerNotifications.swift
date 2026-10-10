// Scribe/UI/Notes/PowerNotes/NotePowerNotifications.swift
import Foundation

extension Notification.Name {
    /// Posted on the main thread, synchronously, just before Scribe rewrites
    /// notes in-app outside their editors (restoring a version, linking an
    /// unlinked mention). `userInfo[NoteVaultChange.noteIdsKey]` holds the
    /// affected ids. Open editors of those notes flush unsaved edits so the
    /// rewrite starts from — and keeps — them. Follow the write with
    /// `.scribeNoteChangedInApp` so the editors reload.
    static let scribeNoteWillChangeInApp = Notification.Name("scribe.noteWillChangeInApp")
}

/// Scrolls the editor that is about to show a note to a line once it has
/// loaded (after navigating to `[[Note#Heading]]` / `[[Note#^block]]`).
@MainActor
enum NoteEditorDeferredScroll {
    static func scroll(toLine line: Int) {
        let command = WebEditorCommand.scrollToLine(line)
        Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(300))
                if WebEditorCommandCenter.shared.send(command) { return }
            }
        }
    }
}
