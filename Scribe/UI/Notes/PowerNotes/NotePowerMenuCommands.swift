// Scribe/UI/Notes/PowerNotes/NotePowerMenuCommands.swift
import AppKit
import SwiftUI

/// Menu commands for note power features:
/// File › New Note from Template… (⌥⌘N), File › Version History…,
/// Edit › Copy Block Link (⇧⌥⌘C).
struct NotePowerMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            NewNoteFromTemplateMenuItem()
        }
        CommandGroup(after: .saveItem) {
            VersionHistoryMenuItem()
        }
        CommandGroup(after: .pasteboard) {
            CopyBlockLinkMenuItem()
        }
    }
}

private struct NewNoteFromTemplateMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Note from Template\u{2026}") {
            NoteTemplatePanelController.shared.presentNewNote(openMainWindow: {
                openWindow(id: "main")
            })
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

private struct VersionHistoryMenuItem: View {
    @FocusedValue(\.scribeNote) private var note

    var body: some View {
        Button("Version History\u{2026}") {
            guard let note else { return }
            // Let the editor's pending autosave land first.
            NotificationCenter.default.post(name: .scribeNoteWillChangeInApp, object: nil,
                                            userInfo: [NoteVaultChange.noteIdsKey: Set([note.noteId])])
            VersionHistoryWindowController.shared.show(noteId: note.noteId, title: note.title)
        }
        .disabled(note == nil)
    }
}

private struct CopyBlockLinkMenuItem: View {
    @FocusedValue(\.scribeNote) private var note
    @FocusedValue(\.scribeEditorCommands) private var editor

    var body: some View {
        Button("Copy Block Link") {
            guard let note else { return }
            guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                AppState.shared.report("Give this note a title before copying a block link.")
                return
            }
            if !WebEditorCommandCenter.shared.send(NotePowerEditorCommands.copyBlockLink(noteTitle: note.title)) {
                NSSound.beep()
            }
        }
        .keyboardShortcut("c", modifiers: [.command, .option, .shift])
        .disabled(note == nil || editor == nil)
    }
}
