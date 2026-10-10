// ScribeiOS/Recording/MobileRecordingController.swift
//
// The iPhone / iPad recorder: microphone capture (MobileAudioCapture) →
// on-device transcription (the Mac's portable `TranscriptionPipeline`,
// SpeechAnalyzer + SpeechTranscriber) → transcript segments in the local
// database, bound to a meeting note in the (iCloud) vault. Handles pause /
// resume, bookmarks, phone-call interruptions, route changes (AirPods), the
// Live Activity, and kicks off the post-recording summary.
//
// Entry points for other areas:
//   • `perform(.start / .stop / .toggle …)` — scribe://record/start|stop
//     (the shell's `navigator.recordRequest`) and App Intents.
//   • `start(linkingNoteId:)` — record into an existing note.

@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Where a recording is in its life.
enum MobileRecordingPhase: Equatable, Sendable {
    case idle
    /// Permissions, note + session, speech model, audio session.
    case preparing
    case recording
    case paused
    /// Finalizing the transcript and closing the audio file.
    case finishing
}

/// A command from an entry point (deep link, intent, Live Activity).
enum MobileRecordingCommand: String, Sendable {
    case start
    case stop
    case toggle
    case pause
    case resume
    case togglePause
}

/// One paragraph of the live transcript feed.
struct MobileLiveLine: Identifiable, Equatable, Sendable {
    let id: UUID
    var startMs: Int
    var speaker: String
    var text: String
}

@MainActor
@Observable
final class MobileRecordingController {

    static let shared = MobileRecordingController(
        transcriptStore: TranscriptStore.shared,
        noteStore: NoteStore.shared,
        taskStore: TaskStore.shared,
        bookmarkStore: SessionBookmarkStore.shared
    )

    // MARK: - Observable state

    private(set) var phase: MobileRecordingPhase = .idle
    private(set) var title = ""
    private(set) var sessionId: String?
    private(set) var noteId: String?
    /// Active (pause-excluded) recording time.
    private(set) var elapsedSeconds: Double = 0
    /// 0…1 input level for the meter.
    private(set) var level: Double = 0
    /// Persisted paragraphs of this recording (latest last, capped).
    private(set) var lines: [MobileLiveLine] = []
    /// The paragraph still being spoken (not persisted yet).
    private(set) var pendingLine: MobileLiveLine?
    /// The recognizer's volatile text for the words being spoken right now.
    private(set) var partialText = ""
    private(set) var bookmarks: [SessionBookmark] = []
    /// e.g. "iPhone Microphone", "AirPods Pro".
    private(set) var inputName: String?
    /// A short status ("Preparing the speech model…", "Paused — call").
    private(set) var statusMessage: String?
    /// True while paused because a call (or Siri, an alarm…) took the mic.
    private(set) var isPausedByInterruption = false
    /// The recording that finished last (the UI opens its transcript).
    private(set) var lastFinishedSessionId: String?
    /// Sessions whose summary / recap is still being produced.
    private(set) var processingSessionIds: Set<String> = []
    /// Bumped whenever the list of recordings may have changed.
    private(set) var recordingsVersion = 0
    /// When the running recording started (wall clock); nil when idle.
    private(set) var recordingStartedAt: Date?
    /// A user-facing failure; the UI clears it.
    var errorMessage: String?

    // MARK: - Collaborators

    private let transcriptStore: TranscriptStore
    private let noteStore: NoteStore
    private let taskStore: TaskStore
    private let bookmarkStore: SessionBookmarkStore
    private let audioSession = MobileAudioSessionCoordinator()
    private let capture = MobileMicrophoneCapture()
    private let gate = MobileCaptureGate()
    private let levelBox = MobileLevelBox()
    private let liveActivity = RecordingLiveActivityController()

    // MARK: - Session state

    @ObservationIgnored private var pipeline: TranscriptionPipeline?
    @ObservationIgnored private var recorder: SessionAudioRecorder?
    @ObservationIgnored private var coalescer: LiveTranscriptCoalescer
    @ObservationIgnored private var clock = SessionClock()
    /// Audio frames (16 kHz) handed to the recognizer — the transcript clock.
    @ObservationIgnored private var fedFrames = 0
    @ObservationIgnored private var createdNoteId: String?
    @ObservationIgnored private var localeIdentifier: String?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var activityTimerStart = Date()
    @ObservationIgnored private var lastActivityPush = Date.distantPast

    @ObservationIgnored private var deliveryContinuation: AsyncStream<MobileCapturedBuffer>.Continuation?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    /// Live feed cap (older paragraphs stay in the database and the detail
    /// screen).
    private static let maxLiveLines = 300

    init(transcriptStore: TranscriptStore, noteStore: NoteStore, taskStore: TaskStore, bookmarkStore: SessionBookmarkStore) {
        self.transcriptStore = transcriptStore
        self.noteStore = noteStore
        self.taskStore = taskStore
        self.bookmarkStore = bookmarkStore
        self.coalescer = LiveTranscriptCoalescer(
            maxSpanMs: MobileRecordingDefaults.liveMaxSpanMs,
            maxGapMs: MobileRecordingDefaults.liveMaxGapMs
        )
        liveActivity.endStaleActivities()
        ScribeRecordingActivityCommands.handler = { @MainActor [weak self] command in
            guard let self else { return }
            switch command {
            case .stop: await self.stop()
            case .togglePause: self.togglePause()
            }
        }
        // Siri / Shortcuts / Control Center / widgets reach the recorder
        // through this hook (ScribeiOS/System/ScribeRecordingControl.swift).
        ScribeRecordingControlRegistry.register(self)
    }

    var isActive: Bool { phase != .idle }
    var canBookmark: Bool { phase == .recording || phase == .paused }
    private var fedMs: Int { Int(Double(fedFrames) / 16.0) }

    // MARK: - Commands

    func perform(_ command: MobileRecordingCommand) async {
        switch command {
        case .start:
            if phase == .idle { await start(linkingNoteId: nil) }
        case .stop:
            await stop()
        case .toggle:
            if phase == .idle {
                await start(linkingNoteId: nil)
            } else {
                await stop()
            }
        case .pause:
            pause()
        case .resume:
            resume()
        case .togglePause:
            togglePause()
        }
    }

    func togglePause() {
        if phase == .recording {
            pause()
        } else if phase == .paused {
            resume()
        }
    }

    // MARK: - Start

    /// Starts recording into `linkingNoteId`, or into a new meeting note
    /// (named after the calendar event in progress when allowed).
    func start(linkingNoteId: String?) async {
        guard phase == .idle else { return }
        phase = .preparing
        stopRequested = false
        errorMessage = nil
        statusMessage = "Getting ready…"
        do {
            guard await MobileAudioSessionCoordinator.requestMicrophonePermission() else {
                throw MobileAudioCaptureError.microphoneDenied
            }
            guard await SpeechRecognizerEngine.checkAuthorization() == .authorized else {
                throw MobileAudioCaptureError.speechDenied
            }
            try checkNotCancelled()
            try await begin(linkingNoteId: linkingNoteId)
        } catch {
            await rollBack()
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
                Log.app.error("iOS recording failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func begin(linkingNoteId: String?) async throws {
        let now = Date()
        let event = MobileCalendarLookup.matchingEvent(at: now)

        // The meeting note.
        let boundNoteId: String
        let noteTitle: String
        if let linkingNoteId, let existing = try noteStore.fetchNote(id: linkingNoteId) {
            boundNoteId = existing.id
            noteTitle = existing.title.isEmpty
                ? MobileRecordingTitle.noteTitle(event: event, date: now, locale: .current, timeZone: .current)
                : existing.title
        } else {
            noteTitle = MobileRecordingTitle.noteTitle(event: event, date: now, locale: .current, timeZone: .current)
            let fallback = (event.map(CalendarNoteFormatter.noteHeader(for:)) ?? "")
                + MobileRecordingTitle.recordedOnLine(deviceName: UIDevice.current.model) + "\n"
            let body = NoteTemplateDefaults.meetingNoteBody(
                fileStore: noteStore.fileStore,
                fallback: fallback,
                title: noteTitle,
                meetingTitle: event?.displayTitle,
                attendees: event?.attendees.map(\.displayName) ?? [],
                date: now
            )
            let note = try noteStore.createNote(title: noteTitle, body: body)
            boundNoteId = note.id
            createdNoteId = note.id
        }

        // The session (+ its audio folder when audio is kept).
        let newSessionId = UUID().uuidString
        let audioDirectory = MobileRecordingSettings.keepAudio
            ? SessionAudioStorage.directory(forSessionId: newSessionId, root: SessionAudioStorage.defaultRoot())
            : nil
        _ = try transcriptStore.createSession(
            title: noteTitle,
            noteId: boundNoteId,
            id: newSessionId,
            audioDirectory: audioDirectory?.path
        )
        if let event {
            try? transcriptStore.setCalendarEvent(
                sessionId: newSessionId,
                eventId: event.id,
                eventTitle: event.displayTitle,
                attendees: event.attendees
            )
        }
        sessionId = newSessionId
        noteId = boundNoteId
        title = noteTitle
        lines = []
        pendingLine = nil
        partialText = ""
        bookmarks = []
        fedFrames = 0
        coalescer = LiveTranscriptCoalescer(
            maxSpanMs: MobileRecordingDefaults.liveMaxSpanMs,
            maxGapMs: MobileRecordingDefaults.liveMaxGapMs
        )
        try checkNotCancelled()

        // Speech first, so it's ready when audio arrives (may download the
        // on-device model on first use).
        statusMessage = "Preparing on-device transcription…"
        let pipeline = TranscriptionPipeline(speaker: MobileRecordingDefaults.speakerKey)
        wire(pipeline)
        self.pipeline = pipeline
        let locale = SpeechRecognizerEngine.resolveLocale(MobileRecordingSettings.language)
        localeIdentifier = locale.identifier
        try await pipeline.start(locale: locale)
        try checkNotCancelled()

        // Audio.
        try audioSession.activateForRecording()
        wireAudioSession()
        audioSession.startObserving(engine: capture.engine)
        recorder = audioDirectory.map { SessionAudioRecorder(directory: $0) }
        startDelivery()
        gate.set(open: true)
        try startCapture()
        try checkNotCancelled()

        clock = SessionClock()
        clock.beginRun(atHostSeconds: Self.hostNow())
        activityTimerStart = Date()
        phase = .recording
        recordingStartedAt = now
        statusMessage = nil
        inputName = audioSession.currentInputName
        ScribeRecordingControlRegistry.recordingStateDidChange()
        startTicking()
        liveActivity.start(title: noteTitle, sessionId: newSessionId, state: activityState())
        lastActivityPush = Date()
        recordingsVersion += 1
        Log.app.info("iOS recording started — session \(newSessionId, privacy: .public), locale \(locale.identifier, privacy: .public)")
    }

    private func checkNotCancelled() throws {
        if stopRequested { throw CancellationError() }
    }

    /// Undoes a start that failed or was cancelled.
    private func rollBack() async {
        tickTask?.cancel()
        tickTask = nil
        restartTask?.cancel()
        restartTask = nil
        gate.set(open: false)
        capture.stop()
        audioSession.stopObserving()
        deliveryContinuation?.finish()
        deliveryContinuation = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        await pipeline?.stop()
        pipeline = nil
        await Self.finishRecorder(recorder)
        recorder = nil
        audioSession.deactivate()
        liveActivity.end(nil)
        if let sessionId {
            try? transcriptStore.deleteSession(id: sessionId)
        }
        if let createdNoteId {
            try? noteStore.deleteNote(id: createdNoteId)
        }
        resetLiveState()
    }

    // MARK: - Pause / resume

    func pause() {
        pause(reason: nil, byInterruption: false)
    }

    private func pause(reason: String?, byInterruption: Bool) {
        guard phase == .recording else { return }
        gate.set(open: false)
        clock.endRun(atHostSeconds: Self.hostNow())
        elapsedSeconds = clock.sessionSeconds(atHostSeconds: Self.hostNow())
        phase = .paused
        isPausedByInterruption = byInterruption
        statusMessage = reason
        // A pause ends the paragraph being spoken.
        if let closed = coalescer.flush() { persist(closed) }
        partialText = ""
        pushLiveActivity(force: true)
    }

    func resume() {
        guard phase == .paused else { return }
        // A call (or a route change while paused) stops the engine.
        if !capture.engine.isRunning {
            do {
                try restartCapture()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        gate.set(open: true)
        clock.beginRun(atHostSeconds: Self.hostNow())
        activityTimerStart = Date().addingTimeInterval(-clock.sessionSeconds(atHostSeconds: Self.hostNow()))
        phase = .recording
        isPausedByInterruption = false
        statusMessage = nil
        pushLiveActivity(force: true)
    }

    // MARK: - Bookmarks

    /// Marks the current moment (optionally labelled).
    func addBookmark(label: String?) {
        guard canBookmark, let sessionId else { return }
        do {
            let bookmark = try bookmarkStore.add(sessionId: sessionId, offsetMs: fedMs, label: label, createdAt: Date())
            bookmarks.append(bookmark)
        } catch {
            errorMessage = "Couldn't save the bookmark: \(error.localizedDescription)"
        }
    }

    // MARK: - Stop

    /// Stops the recording, finalizes the transcript and starts the summary.
    /// While still starting, cancels the start instead.
    func stop() async {
        switch phase {
        case .preparing:
            stopRequested = true
            return
        case .recording, .paused:
            break
        case .idle, .finishing:
            return
        }
        phase = .finishing
        statusMessage = "Finishing the transcript…"
        gate.set(open: false)
        clock.endRun(atHostSeconds: Self.hostNow())
        elapsedSeconds = clock.sessionSeconds(atHostSeconds: Self.hostNow())
        tickTask?.cancel()
        tickTask = nil
        restartTask?.cancel()
        restartTask = nil

        capture.stop()
        audioSession.stopObserving()
        // Deliver what's still queued, then let the recognizer finalize.
        deliveryContinuation?.finish()
        deliveryContinuation = nil
        await deliveryTask?.value
        deliveryTask = nil
        await pipeline?.stop()
        pipeline = nil
        if let closed = coalescer.flush() { persist(closed) }
        await Self.finishRecorder(recorder)
        recorder = nil
        audioSession.deactivate()

        let finishedSessionId = sessionId
        let finalState = activityState()
        liveActivity.end(finalState)

        var keep = true
        if let finishedSessionId {
            keep = finalizeSession(id: finishedSessionId)
        }
        resetLiveState()
        recordingsVersion += 1
        if keep, let finishedSessionId {
            lastFinishedSessionId = finishedSessionId
            runPostProcessing(sessionId: finishedSessionId, summarize: MobileRecordingSettings.summarize)
        }
    }

    /// Ends the session row with the active duration. A recording that
    /// captured nothing (stopped within a couple of seconds) is discarded,
    /// with the note it created. Returns whether the session was kept.
    private func finalizeSession(id: String) -> Bool {
        let segments = (try? transcriptStore.fetchSegments(sessionId: id)) ?? []
        if segments.isEmpty, elapsedSeconds < 2 {
            if let createdNoteId {
                try? noteStore.deleteNote(id: createdNoteId)
            } else {
                try? transcriptStore.deleteSession(id: id)
            }
            return false
        }
        guard var session = try? transcriptStore.fetchSession(id: id) else { return false }
        session.endedAt = Date()
        session.durationSeconds = Int(elapsedSeconds.rounded())
        session.language = localeIdentifier
        try? transcriptStore.updateSession(session)
        return true
    }

    /// Summary, action items → tasks and the note recap, in the background.
    func runPostProcessing(sessionId: String, summarize: Bool) {
        guard !processingSessionIds.contains(sessionId) else { return }
        processingSessionIds.insert(sessionId)
        let processor = RecordingPostProcessor(
            transcriptStore: transcriptStore,
            noteStore: noteStore,
            taskStore: taskStore,
            bookmarkStore: bookmarkStore
        )
        Task { [weak self] in
            let outcome = await processor.process(sessionId: sessionId, summarize: summarize)
            guard let self else { return }
            self.processingSessionIds.remove(sessionId)
            self.recordingsVersion += 1
            if let problem = outcome.summaryProblem, summarize {
                Log.intelligence.info("iOS recording summary skipped: \(problem, privacy: .public)")
            }
        }
    }

    private func resetLiveState() {
        phase = .idle
        sessionId = nil
        noteId = nil
        title = ""
        level = 0
        partialText = ""
        pendingLine = nil
        statusMessage = nil
        inputName = nil
        isPausedByInterruption = false
        createdNoteId = nil
        localeIdentifier = nil
        stopRequested = false
        recordingStartedAt = nil
        // Back to idle (stopped, or a start that failed / was cancelled):
        // refresh the widgets' recording state.
        ScribeRecordingControlRegistry.recordingStateDidChange()
    }

    // MARK: - Audio plumbing

    private func startDelivery() {
        deliveryContinuation?.finish()
        let (stream, continuation) = AsyncStream<MobileCapturedBuffer>.makeStream()
        deliveryContinuation = continuation
        deliveryTask = Task { [weak self] in
            for await captured in stream {
                guard let self else { return }
                self.deliver(captured.buffer)
            }
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let pipeline else { return }
        pipeline.append(buffer)
        fedFrames += Int(buffer.frameLength)
    }

    private func startCapture() throws {
        guard let continuation = deliveryContinuation else { return }
        try capture.start(
            deliver: Self.makeForwarder(gate: gate, recorder: recorder, continuation: continuation),
            level: Self.makeLevelForwarder(levelBox)
        )
    }

    /// Rebuilds the tap for the current input (new route / format).
    private func restartCapture() throws {
        capture.stop()
        try audioSession.activateForRecording()
        try startCapture()
        inputName = audioSession.currentInputName
    }

    /// Built outside the main actor: runs on the render thread. Writes the
    /// buffer to the audio file (the recorder's own queue does the disk work)
    /// and hands it to the main actor for transcription.
    nonisolated private static func makeForwarder(
        gate: MobileCaptureGate,
        recorder: SessionAudioRecorder?,
        continuation: AsyncStream<MobileCapturedBuffer>.Continuation
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in
            guard gate.isOpen else { return }
            recorder?.appendMic(buffer)
            continuation.yield(MobileCapturedBuffer(buffer: buffer))
        }
    }

    nonisolated private static func makeLevelForwarder(_ box: MobileLevelBox) -> @Sendable (Float) -> Void {
        { peak in box.record(peak) }
    }

    private func wireAudioSession() {
        audioSession.onInterruption = { [weak self] event in
            self?.handle(event)
        }
        audioSession.onRouteChange = { [weak self] change in
            self?.handle(change)
        }
        audioSession.onEngineConfigurationChange = { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.scheduleInputRestart()
        }
        audioSession.onMediaServicesReset = { [weak self] in
            guard let self, self.phase == .recording || self.phase == .paused else { return }
            self.errorMessage = "iOS reset its audio services, so the recording was stopped. What was captured so far is kept."
            Task { await self.stop() }
        }
    }

    private func handle(_ interruption: MobileAudioInterruption) {
        let action = MobileRecordingInterruptionPolicy.action(
            for: interruption,
            isCapturing: phase == .recording,
            isPausedByUser: phase == .paused && !isPausedByInterruption,
            wasPausedByInterruption: phase == .paused && isPausedByInterruption
        )
        switch action {
        case .pause:
            pause(reason: "Paused while the microphone is in use by a call.", byInterruption: true)
        case .resume:
            resume()
        case .restartInput:
            scheduleInputRestart()
        case .ignore:
            break
        }
    }

    private func handle(_ change: MobileAudioRouteChange) {
        switch MobileRecordingInterruptionPolicy.action(for: change, isCapturing: phase == .recording) {
        case .restartInput:
            scheduleInputRestart()
        case .pause:
            pause(reason: "Paused — no microphone is available.", byInterruption: false)
        case .resume, .ignore:
            break
        }
    }

    /// Coalesces bursts of route / configuration notifications into one tap
    /// rebuild.
    private func scheduleInputRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.phase == .recording else { return }
            // Route notifications also fire for changes the running tap
            // survives (e.g. the output switching); only rebuild when needed.
            guard self.capture.needsRestart else { return }
            do {
                try self.restartCapture()
                Log.audio.info("iOS recording input restarted (\(self.inputName ?? "unknown", privacy: .public)).")
            } catch {
                self.errorMessage = error.localizedDescription
                self.pause(reason: "Paused — the microphone couldn't be restarted.", byInterruption: false)
            }
        }
    }

    // MARK: - Transcript

    private func wire(_ pipeline: TranscriptionPipeline) {
        pipeline.onSegment = { [weak self] segment in
            self?.ingest(segment)
        }
        pipeline.onPartialUpdate = { [weak self] text in
            self?.partialText = text
        }
        pipeline.onError = { [weak self] error in
            guard let self else { return }
            self.errorMessage = "Transcription stopped: \(error.localizedDescription)"
            Log.speech.error("iOS pipeline error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingest(_ segment: TranscriptionSegment) {
        let piece = LiveTranscriptCoalescer.Piece(
            startMs: segment.startMs,
            endMs: segment.endMs,
            speaker: segment.speaker,
            text: segment.text
        )
        if let closed = coalescer.ingest(piece) { persist(closed) }
        refreshPendingLine()
    }

    private func persist(_ piece: LiveTranscriptCoalescer.Piece) {
        defer { refreshPendingLine() }
        guard let sessionId else { return }
        do {
            try transcriptStore.addSegment(
                sessionId: sessionId,
                startMs: piece.startMs,
                endMs: piece.endMs,
                speaker: piece.speaker,
                text: piece.text
            )
        } catch {
            errorMessage = "Couldn't save the transcript: \(error.localizedDescription)"
            return
        }
        lines.append(MobileLiveLine(id: UUID(), startMs: piece.startMs,
                                    speaker: Self.displayName(piece.speaker), text: piece.text))
        if lines.count > Self.maxLiveLines {
            lines.removeFirst(lines.count - Self.maxLiveLines)
        }
        pushLiveActivity(force: false)
    }

    private func refreshPendingLine() {
        guard let pending = coalescer.pending else {
            pendingLine = nil
            return
        }
        let id = pendingLine?.id ?? UUID()
        pendingLine = MobileLiveLine(id: id, startMs: pending.startMs,
                                     speaker: Self.displayName(pending.speaker), text: pending.text)
    }

    private static func displayName(_ speakerKey: String) -> String {
        SpeakerNameResolver().displayName(forKey: speakerKey)
    }

    // MARK: - Ticking (meter, clock, idle paragraphs, Live Activity)

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let peak = levelBox.drain()
        let target = phase == .recording ? MobileAudioLevelScale.normalized(linearPeak: peak) : 0
        level = MobileAudioLevelScale.smoothed(previous: level, next: target)
        elapsedSeconds = clock.sessionSeconds(atHostSeconds: Self.hostNow())
        if phase == .recording, let closed = coalescer.closeIfIdle(audioClockMs: fedMs) {
            persist(closed)
        }
    }

    private func activityState() -> ScribeRecordingActivityAttributes.ContentState {
        let latest = pendingLine?.text ?? lines.last?.text ?? ""
        return ScribeRecordingActivityAttributes.ContentState(
            timerStart: activityTimerStart,
            elapsedSeconds: clock.sessionSeconds(atHostSeconds: Self.hostNow()),
            isPaused: phase == .paused,
            latestLine: String(latest.suffix(140))
        )
    }

    /// Pause / resume push at once; transcript lines at most every 10 s.
    private func pushLiveActivity(force: Bool) {
        guard force || Date().timeIntervalSince(lastActivityPush) >= 10 else { return }
        lastActivityPush = Date()
        liveActivity.update(activityState())
    }

    // MARK: - Helpers

    nonisolated private static func hostNow() -> Double {
        Date().timeIntervalSinceReferenceDate
    }

    /// Closes the audio file off the main actor (it drains the encoder queue).
    private static func finishRecorder(_ recorder: SessionAudioRecorder?) async {
        guard let recorder else { return }
        await Task.detached(priority: .utility) {
            recorder.finish()
        }.value
    }
}
