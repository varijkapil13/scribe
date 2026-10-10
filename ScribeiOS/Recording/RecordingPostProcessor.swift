// ScribeiOS/Recording/RecordingPostProcessor.swift
//
// What runs after an iPhone / iPad recording (or import) ends: the on-device
// summary (Foundation Models, via the Mac's portable `MeetingSummarizer`),
// action items → tasks (`ActionItemConverter`), and the recap written into the
// meeting note (`MeetingNoteRecap`) so the results sync to the Mac through
// the iCloud vault.
//
// Speaker diarization (FluidAudio, Scribe/Diarization) is NOT part of the iOS
// target: its coordinator, settings and bundled-model plumbing are macOS-only,
// and nothing in CI proves the package builds for iOS. iOS recordings keep a
// single "In person" speaker the user can rename.

import Foundation
import FoundationModels
import UIKit

@MainActor
final class RecordingPostProcessor {

    struct Outcome: Equatable {
        var summarized = false
        var tasksCreated = 0
        var wroteNote = false
        /// Why the summary was skipped / failed, for the detail screen.
        var summaryProblem: String?
    }

    private let transcriptStore: TranscriptStore
    private let noteStore: NoteStore
    private let taskStore: TaskStore
    private let bookmarkStore: SessionBookmarkStore

    init(transcriptStore: TranscriptStore, noteStore: NoteStore, taskStore: TaskStore, bookmarkStore: SessionBookmarkStore) {
        self.transcriptStore = transcriptStore
        self.noteStore = noteStore
        self.taskStore = taskStore
        self.bookmarkStore = bookmarkStore
    }

    /// Whether the on-device model can run right now.
    static var isSummarizerAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Runs the post-recording work for `sessionId`. Asks iOS for background
    /// time so a recording stopped from the Lock Screen still finishes.
    func process(sessionId: String, summarize: Bool) async -> Outcome {
        let background = BackgroundTaskToken(name: "Finish Scribe recording")
        defer { background.end() }

        var outcome = Outcome()
        guard let session = try? transcriptStore.fetchSession(id: sessionId) else { return outcome }
        let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
        let resolver = transcriptStore.speakerResolver(sessionId: sessionId)

        var summaryMarkdown: String?
        if summarize, !segments.isEmpty {
            if Self.isSummarizerAvailable {
                do {
                    let summary = try await MeetingSummarizer.summarize(
                        sessionId: sessionId,
                        title: session.title,
                        segments: segments.map {
                            (speaker: resolver.displayName(for: $0), text: $0.text, timestamp: $0.formattedTimestamp)
                        }
                    )
                    try transcriptStore.saveSummary(summary)
                    summaryMarkdown = MeetingNoteRecap.summaryMarkdown(summary)
                    outcome.summarized = true
                    if MobileRecordingSettings.actionItemsToTasks {
                        outcome.tasksCreated = convertActionItems(summary.actionItems, sessionId: sessionId,
                                                                  noteId: session.noteId)
                    }
                } catch {
                    outcome.summaryProblem = error.localizedDescription
                    Log.intelligence.error("iOS summary failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                outcome.summaryProblem = "Apple Intelligence isn't available on this device right now."
            }
        }

        if let noteId = session.noteId {
            let bookmarks = (try? bookmarkStore.fetch(sessionId: sessionId)) ?? []
            let highlights = SessionBookmarkFormatter.noteBlockContent(
                bookmarks: bookmarks,
                segments: segments,
                speakerName: { resolver.displayName(for: $0) }
            )
            let transcript = MobileRecordingSettings.transcriptInNote
                ? MeetingNoteRecap.transcriptMarkdown(segments: segments, speakerName: { resolver.displayName(for: $0) })
                : nil
            do {
                outcome.wroteNote = try MeetingNoteRecapWriter(noteStore: noteStore).write(
                    noteId: noteId,
                    sessionId: sessionId,
                    summary: summaryMarkdown,
                    highlights: highlights,
                    transcript: transcript
                )
            } catch {
                Log.storage.error("Couldn't write the recording recap into its note: \(error.localizedDescription, privacy: .public)")
            }
        }
        return outcome
    }

    /// Creates a task per new action item. Tasks land in the meeting note's
    /// project when the note sits in one. Returns how many were created.
    func convertActionItems(_ items: [ActionItem], sessionId: String, noteId: String?) -> Int {
        let converted = Set(items.compactMap { item -> String? in
            let id = item.id.uuidString
            return (try? taskStore.fetchTaskForActionItem(id)) != nil ? id : nil
        })
        let projectId = noteId.flatMap { try? noteStore.fetchNote(id: $0) }?.notebookId
        var created = 0
        for item in MeetingNoteRecap.itemsToConvert(items, convertedIds: converted) {
            let draft = ActionItemConverter.draft(from: item, sessionId: sessionId, projectId: projectId)
            do {
                try taskStore.createTask(
                    title: draft.title,
                    notes: draft.notes,
                    projectId: draft.projectId,
                    priority: draft.priority,
                    dueAt: draft.dueAt,
                    sourceSessionId: draft.sourceSessionId,
                    sourceActionItemId: draft.sourceActionItemId,
                    tags: draft.tags
                )
                created += 1
            } catch {
                Log.storage.error("Couldn't turn an action item into a task: \(error.localizedDescription, privacy: .public)")
            }
        }
        return created
    }
}

/// A `UIApplication` background task that ends exactly once.
@MainActor
final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        // UIKit calls the expiration handler on the main thread. Asserting
        // that explicitly compiles whether the SDK types the handler as
        // `@MainActor @Sendable` or as a plain `@Sendable` closure.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
