import AppKit
import Combine
import Foundation
import KeyboardShortcuts

/// An "Ask now" answer during a recording.
struct LiveCopilotAnswer: Equatable, Sendable {
    var question: String
    var answer: String
    var usedModel: Bool
    var notice: String?
}

/// Drives the live meeting copilot for the current recording: the rolling
/// summary (refreshed every ~2 minutes of new transcript, or on demand),
/// "Ask now", and bookmarked moments (⌃⌥M). One shared instance follows
/// `AppState.currentSessionId`, so the hotkey, the live view and the
/// in-note pane all see the same state.
@MainActor
final class LiveCopilotController: ObservableObject {

    static let shared = LiveCopilotController(
        transcriptStore: .shared,
        bookmarkStore: .shared
    )

    // MARK: Published state

    /// Session being followed (nil when not recording).
    @Published private(set) var sessionId: String?
    @Published private(set) var state: LiveCopilotState = .empty
    @Published private(set) var isUpdating = false
    @Published private(set) var lastUpdated: Date?
    /// True when the last update came from the on-device model.
    @Published private(set) var usedModel = false
    /// Why the model wasn't used / failed, when relevant.
    @Published private(set) var notice: String?
    @Published private(set) var bookmarks: [SessionBookmark] = []

    @Published private(set) var isAnswering = false
    @Published private(set) var answer: LiveCopilotAnswer?

    // MARK: Dependencies / bookkeeping

    private let transcriptStore: TranscriptStore
    private let bookmarkStore: SessionBookmarkStore
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var loopTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var shortcutRegistered = false

    /// Id of the last segment folded into `state`.
    private var lastProcessedSegmentId: Int64 = 0
    /// Recording time (ms) of the last update.
    private var lastUpdateElapsedMs: Int?

    /// How often the background loop checks whether an update is due.
    private static let pollInterval: Duration = .seconds(15)

    init(transcriptStore: TranscriptStore, bookmarkStore: SessionBookmarkStore) {
        self.transcriptStore = transcriptStore
        self.bookmarkStore = bookmarkStore
    }

    // MARK: Wiring

    /// Follows `appState`'s recording and registers the Mark Moment hotkey.
    /// Called once at launch.
    func install(appState: AppState) {
        self.appState = appState
        cancellables.removeAll()
        appState.$currentSessionId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.sessionChanged(to: id)
            }
            .store(in: &cancellables)

        if !shortcutRegistered {
            shortcutRegistered = true
            KeyboardShortcuts.onKeyUp(for: .markMoment) {
                Task { @MainActor in
                    LiveCopilotController.shared.markMoment(label: nil)
                }
            }
        }
    }

    private func sessionChanged(to newId: String?) {
        guard newId != sessionId else { return }
        if let finished = sessionId {
            finish(sessionId: finished)
        }
        reset()
        sessionId = newId
        guard newId != nil else { return }
        reloadBookmarks()
        startLoop()
    }

    private func reset() {
        loopTask?.cancel()
        loopTask = nil
        updateTask?.cancel()
        updateTask = nil
        askTask?.cancel()
        askTask = nil
        state = .empty
        isUpdating = false
        isAnswering = false
        lastUpdated = nil
        usedModel = false
        notice = nil
        answer = nil
        bookmarks = []
        lastProcessedSegmentId = 0
        lastUpdateElapsedMs = nil
    }

    // MARK: Rolling summary

    private func startLoop() {
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: LiveCopilotController.pollInterval)
                if Task.isCancelled { break }
                self?.tick()
            }
        }
    }

    private var elapsedMs: Int {
        guard let duration = appState?.audioManager.recordingDuration, duration.isFinite else { return 0 }
        return max(0, Int(duration * 1000))
    }

    private func tick() {
        guard CopilotSettings.liveSummaryEnabled(.standard) else { return }
        guard appState?.audioManager.isPaused != true else { return }
        update(force: false)
    }

    /// Refreshes the summary now ("Update now"). No-op when nothing new was
    /// said since the last update.
    func refreshNow() {
        update(force: true)
    }

    private func update(force: Bool) {
        guard let sessionId, updateTask == nil else { return }
        let resolver = transcriptStore.speakerResolver(sessionId: sessionId)
        let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
        let lines = Self.lines(from: segments, resolver: resolver)
        let pending = LiveCopilotScheduler.pendingLines(lines, afterId: lastProcessedSegmentId)
        let intervalMs = CopilotSettings.intervalMinutes(.standard) * 60_000
        let now = elapsedMs
        guard LiveCopilotScheduler.shouldUpdate(
            elapsedMs: now,
            lastUpdateElapsedMs: lastUpdateElapsedMs,
            pendingCharacters: LiveCopilotScheduler.pendingCharacters(pending),
            intervalMs: intervalMs,
            force: force
        ) else { return }

        let batches = LiveCopilotScheduler.batches(pending)
        guard !batches.isEmpty else { return }
        let title = (try? transcriptStore.fetchSession(id: sessionId))?.title ?? ""
        let highlighted = bookmarks.map(\.offsetMs)
        let previous = state
        let available = AppleIntelligenceAvailability.current

        isUpdating = true
        updateTask = Task { [weak self] in
            let outcome = await LiveCopilotController.run(
                batches: batches,
                previous: previous,
                title: title,
                highlightedMs: highlighted,
                availability: available
            )
            self?.apply(outcome, sessionId: sessionId, elapsedMs: now)
        }
    }

    private struct UpdateOutcome: Sendable {
        var state: LiveCopilotState
        var lastSegmentId: Int64?
        var usedModel: Bool
        var notice: String?
    }

    /// Folds each batch into the state in turn. Falls back to the heuristic
    /// extractor when the model is unavailable or a call fails.
    private nonisolated static func run(
        batches: [[LiveCopilotLine]],
        previous: LiveCopilotState,
        title: String,
        highlightedMs: [Int],
        availability: AppleIntelligenceAvailability
    ) async -> UpdateOutcome {
        var current = previous
        var lastId: Int64?
        var usedModel = false
        var notice: String?
        for batch in batches {
            if Task.isCancelled { break }
            if availability.isAvailable && notice == nil {
                let prompt = LiveCopilotPromptBuilder.prompt(
                    title: title, previous: current, chunk: batch, highlightedMs: highlightedMs
                )
                do {
                    let reply = try await MeetingSummarizer.generateText(
                        instructions: LiveCopilotPromptBuilder.instructions,
                        prompt: prompt
                    )
                    if let parsed = LiveCopilotPromptBuilder.parse(reply, previous: current) {
                        current = parsed
                        usedModel = true
                    } else {
                        current = LiveCopilotHeuristics.update(previous: current, lines: batch)
                    }
                } catch {
                    notice = "Live summary paused: \(error.localizedDescription) Showing detected action items and questions instead."
                    current = LiveCopilotHeuristics.update(previous: current, lines: batch)
                }
            } else {
                if case .unavailable(let reason) = availability {
                    notice = "\(reason) Showing detected action items and questions instead of a summary."
                }
                current = LiveCopilotHeuristics.update(previous: current, lines: batch)
            }
            lastId = batch.last?.id ?? lastId
        }
        return UpdateOutcome(state: current, lastSegmentId: lastId, usedModel: usedModel, notice: notice)
    }

    private func apply(_ outcome: UpdateOutcome, sessionId: String, elapsedMs: Int) {
        // The recording may have ended (or another started) meanwhile;
        // `reset()` already cleared the in-flight state then.
        guard self.sessionId == sessionId else { return }
        updateTask = nil
        isUpdating = false
        state = outcome.state
        usedModel = outcome.usedModel
        notice = outcome.notice
        lastUpdated = Date()
        lastUpdateElapsedMs = elapsedMs
        if let lastId = outcome.lastSegmentId {
            lastProcessedSegmentId = max(lastProcessedSegmentId, lastId)
        }
    }

    /// Live-summary lines from persisted segments, with display names.
    static func lines(from segments: [Segment], resolver: SpeakerNameResolver) -> [LiveCopilotLine] {
        segments.compactMap { segment -> LiveCopilotLine? in
            guard let id = segment.id else { return nil }
            return LiveCopilotLine(
                id: id,
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: resolver.displayName(for: segment),
                text: segment.text
            )
        }
    }

    // MARK: Ask now

    /// Answers `question` from the transcript so far (+ the live summary).
    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionId else { return }
        askTask?.cancel()
        let resolver = transcriptStore.speakerResolver(sessionId: sessionId)
        let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
        var lines = Self.lines(from: segments, resolver: resolver)
        // Include the utterance still being spoken (not persisted yet).
        if let appState, let pending = appState.overlaySegments.last,
           !segments.contains(where: { $0.startMs == pending.startMs && $0.text == pending.text }) {
            let nextId = (lines.last?.id ?? 0) + 1
            lines.append(LiveCopilotLine(
                id: nextId,
                startMs: pending.sessionOffsetMs,
                endMs: pending.sessionOffsetMs + max(0, pending.endMs - pending.startMs),
                speaker: resolver.displayName(for: Segment(
                    sessionId: sessionId, startMs: pending.startMs, endMs: pending.endMs,
                    speaker: pending.speaker, text: pending.text
                )),
                text: pending.text
            ))
        }
        let context = LiveCopilotAskBuilder.selectContext(question: trimmed, lines: lines)
        let summary = state.summary
        let availability = AppleIntelligenceAvailability.current

        isAnswering = true
        answer = nil
        askTask = Task { [weak self] in
            let result = await LiveCopilotController.answer(
                question: trimmed, context: context, allLines: lines,
                summary: summary, availability: availability
            )
            guard !Task.isCancelled else { return }
            self?.finishAsk(result, sessionId: sessionId)
        }
    }

    private func finishAsk(_ result: LiveCopilotAnswer, sessionId: String) {
        guard self.sessionId == sessionId else { return }
        isAnswering = false
        askTask = nil
        answer = result
    }

    func clearAnswer() {
        askTask?.cancel()
        askTask = nil
        isAnswering = false
        answer = nil
    }

    private nonisolated static func answer(
        question: String,
        context: [LiveCopilotLine],
        allLines: [LiveCopilotLine],
        summary: String,
        availability: AppleIntelligenceAvailability
    ) async -> LiveCopilotAnswer {
        guard availability.isAvailable else {
            var reason = "Apple Intelligence isn't available right now."
            if case .unavailable(let detail) = availability { reason = detail }
            return LiveCopilotAnswer(
                question: question,
                answer: LiveCopilotAskBuilder.fallbackAnswer(question: question, lines: allLines),
                usedModel: false,
                notice: reason
            )
        }
        do {
            let reply = try await MeetingSummarizer.generateText(
                instructions: LiveCopilotAskBuilder.instructions,
                prompt: LiveCopilotAskBuilder.prompt(question: question, context: context, liveSummary: summary)
            )
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return LiveCopilotAnswer(question: question, answer: text, usedModel: true, notice: nil)
            }
        } catch {
            return LiveCopilotAnswer(
                question: question,
                answer: LiveCopilotAskBuilder.fallbackAnswer(question: question, lines: allLines),
                usedModel: false,
                notice: "Couldn't generate an answer (\(error.localizedDescription))."
            )
        }
        return LiveCopilotAnswer(
            question: question,
            answer: LiveCopilotAskBuilder.fallbackAnswer(question: question, lines: allLines),
            usedModel: false,
            notice: nil
        )
    }

    // MARK: Bookmarks

    /// Bookmarks the current moment of the recording. Beeps when nothing is
    /// recording.
    func markMoment(label: String?) {
        guard let sessionId else {
            NSSound.beep()
            return
        }
        let offset = elapsedMs
        do {
            try bookmarkStore.add(sessionId: sessionId, offsetMs: offset, label: label, createdAt: Date())
            reloadBookmarks()
            appState?.notify("Marked moment at \(SessionBookmarkFormatter.shortTimestamp(ms: offset))")
        } catch {
            appState?.report("Couldn't save the bookmark: \(error.localizedDescription)")
        }
    }

    func renameBookmark(_ bookmark: SessionBookmark, to label: String) {
        guard let id = bookmark.id else { return }
        try? bookmarkStore.updateLabel(id: id, label: label)
        reloadBookmarks()
    }

    func deleteBookmark(_ bookmark: SessionBookmark) {
        guard let id = bookmark.id else { return }
        try? bookmarkStore.delete(id: id)
        reloadBookmarks()
    }

    private func reloadBookmarks() {
        guard let sessionId else {
            bookmarks = []
            return
        }
        bookmarks = (try? bookmarkStore.fetch(sessionId: sessionId)) ?? []
    }

    // MARK: Session end

    /// Writes the session's highlights into its note (Settings permitting).
    private func finish(sessionId: String) {
        guard CopilotSettings.highlightsInNote(.standard) else { return }
        SessionHighlightsWriter.writeToNote(
            sessionId: sessionId,
            transcriptStore: transcriptStore,
            bookmarkStore: bookmarkStore
        )
    }
}

/// Writes a session's bookmarked moments into its meeting note as a Scribe
/// block (replaced in place on re-runs).
@MainActor
enum SessionHighlightsWriter {
    static func writeToNote(
        sessionId: String,
        transcriptStore: TranscriptStore,
        bookmarkStore: SessionBookmarkStore
    ) {
        let bookmarks = (try? bookmarkStore.fetch(sessionId: sessionId)) ?? []
        guard !bookmarks.isEmpty,
              let session = try? transcriptStore.fetchSession(id: sessionId),
              let noteId = session.noteId else { return }
        let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
        let resolver = transcriptStore.speakerResolver(sessionId: sessionId)
        guard let content = SessionBookmarkFormatter.noteBlockContent(
            bookmarks: bookmarks,
            segments: segments,
            speakerName: { resolver.displayName(for: $0) }
        ) else { return }
        do {
            try NoteAIEditWriter.apply(
                .upsertBlock(kind: SessionBookmarkFormatter.noteBlockKind, id: sessionId, markdown: content),
                toNoteId: noteId
            )
        } catch {
            Log.intelligence.error("Writing highlights failed: \(error.localizedDescription)")
        }
    }
}
