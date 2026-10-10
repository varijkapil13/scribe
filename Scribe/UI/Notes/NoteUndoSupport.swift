// Scribe/UI/Notes/NoteUndoSupport.swift
import Foundation

/// Edit › Undo Delete Note.
///
/// Deleting a note is only undoable when it destroys nothing undo can't
/// rebuild: a note with recordings (sessions, segments, summaries, retained
/// audio) or attachment files is deleted as before, without an undo entry.
enum NoteUndo {

    /// What a delete needs to be reversed.
    struct Snapshot {
        let note: Note
        let tags: [String]
        /// The file's other frontmatter keys (typed properties, `font:`, …),
        /// which exist only on disk.
        var extra: [FrontmatterEntry] = []
    }

    /// Pure policy: only notes without recordings or attachments come back.
    nonisolated static func canUndoDelete(sessionCount: Int, hasAttachments: Bool) -> Bool {
        sessionCount == 0 && !hasAttachments
    }

    /// Whether `root/attachments/<noteId>/` holds any files.
    nonisolated static func hasAttachments(noteId: String, root: URL) -> Bool {
        let dir = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(noteId, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }

    /// A snapshot to restore the note from, or nil when its delete can't be
    /// undone safely (or the note is gone).
    static func restorableSnapshot(noteId: String, store: NoteStore, attachmentsRoot: URL) -> Snapshot? {
        guard let note = try? store.fetchNote(id: noteId) else { return nil }
        let sessions = (try? store.sessionCount(forNoteId: noteId)) ?? 1
        let attachments = hasAttachments(noteId: noteId, root: attachmentsRoot)
        guard canUndoDelete(sessionCount: sessions, hasAttachments: attachments) else { return nil }
        let tags = (try? store.tags(for: noteId)) ?? []
        let extra = store.diskEntry(forNoteId: noteId)?.file.frontmatter.extra ?? []
        return Snapshot(note: note, tags: tags, extra: extra)
    }

    /// Deletes the note and, when that is safely reversible, registers
    /// Undo Delete Note (and its Redo) with `undoManager`.
    @MainActor
    static func deleteNote(id noteId: String, store: NoteStore, undoManager: UndoManager?) throws {
        let snapshot = undoManager == nil
            ? nil
            : restorableSnapshot(noteId: noteId, store: store,
                                 attachmentsRoot: AttachmentsDirectory.defaultRoot())
        try store.deleteNote(id: noteId)
        guard let snapshot else { return }
        UndoableActions.register(
            on: undoManager,
            actionName: "Delete Note",
            undo: {
                do {
                    try store.restoreDeletedNote(snapshot.note, tags: snapshot.tags, extra: snapshot.extra)
                } catch {
                    AppState.shared.report("Couldn't restore the note: \(error.localizedDescription)")
                }
            },
            redo: {
                do {
                    try store.deleteNote(id: noteId)
                } catch {
                    AppState.shared.report("Couldn't delete the note: \(error.localizedDescription)")
                }
            }
        )
    }
}
