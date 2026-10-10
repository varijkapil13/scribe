// ScribeiOS/System/IOSIntentsBridge.swift
//
// iOS counterpart of Scribe/Intents/ScribeIntentsBridge.swift (macOS, AppKit;
// not compiled here). The portable intents (Scribe/Intents: notes, tasks,
// meetings, recording) call the same `ScribeIntentsBridge` API on both
// platforms; this file implements it against the iOS app.

import Foundation

@MainActor
enum ScribeIntentsBridge {

    // MARK: - Notes

    static func createNote(title: String, body: String) async throws -> NoteEntity {
        let note = try ScribeIntentsData.live.createNote(title: title, body: body)
        return NoteEntity(note: note)
    }

    /// Appends `text` as its own paragraph. Refuses notes whose file can't be
    /// read (appending would replace the file with just the new text) and
    /// locked notes (their body is ciphertext). Keeps the pre-edit content in
    /// version history and tells an open editor to reload.
    static func append(_ text: String, toNoteId noteId: String) async throws -> NoteEntity {
        let store = NoteStore.shared
        guard var current = try store.fetchNote(id: noteId) else { throw ScribeIntentError.noteNotFound }
        if current.body.isEmpty, !(current.bodyExcerpt ?? "").isEmpty {
            throw ScribeIntentError.noteUnreadable
        }
        if LockedNoteEnvelope.isLocked(current.body) {
            throw ScribeIntentError.noteUnreadable
        }
        let updated = ScribeIntentsText.append(text, to: current.body)
        if updated != current.body {
            current.body = updated
            let tags = try store.tags(for: noteId)
            try store.updateNote(current, tags: tags, versionReason: .aiEdit)
            NotificationCenter.default.post(
                name: .scribeNoteChangedInApp,
                object: nil,
                userInfo: [NoteVaultChange.noteIdsKey: Set([noteId])]
            )
        }
        guard let refreshed = try ScribeIntentsData.live.notes(ids: [noteId]).first else {
            throw ScribeIntentError.noteNotFound
        }
        return NoteEntity(note: refreshed)
    }

    /// `OpenNoteIntent` runs with the app in the foreground; the shell routes
    /// the scribe:// link to the Notes tab.
    static func openNote(id: String) async throws {
        guard try !ScribeIntentsData.live.notes(ids: [id]).isEmpty else { throw ScribeIntentError.noteNotFound }
        IOSSystemIntegration.openInApp(ScribeAppGroup.noteURL(id: id))
    }

    // MARK: - Tasks

    static func createTask(title: String, dueAt: Date?, priority: TodoTask.Priority?, notes: String) throws -> TaskEntity {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScribeIntentError.emptyTitle }
        let task = try TaskStore.shared.createTask(
            title: trimmed,
            notes: notes,
            priority: priority,
            dueAt: dueAt
        )
        return TaskEntity(task: task)
    }

    /// Same as the Mac: recurring tasks advance to their next occurrence and
    /// re-arm their reminder; one-off tasks drop it.
    static func completeTask(id: String) async throws -> TaskEntity {
        let store = TaskStore.shared
        guard let existing = try store.fetchTask(id: id) else { throw ScribeIntentError.taskNotFound }
        if existing.isCompleted { return TaskEntity(task: existing) }
        try store.completeTask(id: id)
        guard let refreshed = try store.fetchTask(id: id) else { throw ScribeIntentError.taskNotFound }
        if refreshed.isCompleted {
            await TaskReminderScheduler.shared.cancel(taskId: id)
        } else {
            await TaskReminderScheduler.shared.schedule(refreshed)
        }
        return TaskEntity(task: refreshed)
    }

    // MARK: - Recording

    /// How long a just-launched app waits for the recorder to register.
    private static let recorderWait: Duration = .seconds(3)

    static var isRecording: Bool {
        ScribeRecordingControlRegistry.current?.isRecordingActive ?? false
    }

    /// Starts a recording through the registered recorder. Without one (the
    /// Record area hasn't registered yet), opens scribe://record/start so the
    /// shell's Record tab starts it. Returns false when one was already
    /// running.
    static func startRecording() async throws -> Bool {
        guard let control = await ScribeRecordingControlRegistry.awaitControl(timeout: recorderWait) else {
            IOSSystemIntegration.openInApp(ScribeAppGroup.recordStartURL)
            return true
        }
        guard !control.isRecordingActive else { return false }
        do {
            try await control.startRecordingFromSystem()
        } catch {
            throw ScribeIntentError.recordingDidNotStart
        }
        return true
    }

    /// Stops the running recording. Returns false when nothing was recording.
    static func stopRecording() async throws -> Bool {
        guard let control = ScribeRecordingControlRegistry.current, control.isRecordingActive else {
            return false
        }
        await control.stopRecordingFromSystem()
        return true
    }
}
