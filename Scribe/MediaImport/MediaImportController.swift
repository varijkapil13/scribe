// Scribe/MediaImport/MediaImportController.swift
import AppKit
import AVFoundation
import Foundation
import Speech

/// Imports audio / video files as recordings (File › Import Recording… and
/// drag-and-drop onto the main window).
///
/// Each file becomes a note plus a session, exactly like a live recording:
/// the audio is decoded to 16 kHz mono (`MediaImportDecoder`), fed through
/// the same `TranscriptionPipeline` the live path uses, written to the
/// session's audio folder as `system.m4a` (so playback and speaker
/// diarization work as for a recording) and the transcript is stored as
/// segments. Then the normal post-recording work runs
/// (`AppState.runPostRecordingProcessing`: diarization, analysis, summary)
/// plus the post-meeting hooks.
///
/// Files are imported one at a time; more files queue up. The import can be
/// cancelled, which removes the half-made note and session.
@MainActor
final class MediaImportController: ObservableObject {

    static let shared = MediaImportController()

    enum Stage: Equatable {
        case preparing
        case transcribing
        case finishing
        case saving
    }

    struct Progress: Equatable {
        var fileName: String
        var stage: Stage
        /// 0…1 while transcribing; nil when indeterminate.
        var fraction: Double?
        /// Files waiting behind this one.
        var queued: Int
        /// Latest recognized text, for a live preview.
        var preview: String
    }

    @Published private(set) var progress: Progress?

    var isImporting: Bool { progress != nil }

    private var queue: [URL] = []
    private var worker: Task<Void, Never>?
    private var job: ImportJob?
    /// The task running the current file's import (cancelled by ``cancel()``).
    private var currentImport: Task<Result<String, any Error>, Never>?

    /// Speaker key stamped on imported segments. "remote" so diarization
    /// splits it into Speaker 1…N, as for the other side of a call.
    nonisolated static let importedSpeaker = "remote"

    // MARK: - Entry points

    /// Shows an open panel and imports the chosen files.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Recording"
        panel.message = "Choose audio or video files to transcribe."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MediaImportFormats.contentTypes
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Queues `urls` for import (unsupported files are reported and skipped).
    func importFiles(_ urls: [URL]) {
        let supported = MediaImportFormats.supported(urls)
        let rejected = urls.filter { !MediaImportFormats.isSupported($0) }
        if let first = rejected.first {
            AppState.shared.report(ScribeMediaImportError.unsupportedFile(first.lastPathComponent))
        }
        guard !supported.isEmpty else { return }
        queue += supported
        if var current = progress {
            current.queued = queue.count
            progress = current
        }
        startWorkerIfNeeded()
    }

    /// Cancels the running import and everything queued.
    func cancel() {
        queue.removeAll()
        currentImport?.cancel()
    }

    // MARK: - Queue

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { await self.processQueue() }
    }

    private func processQueue() async {
        while let next = dequeue() {
            await runImport(of: next)
        }
        worker = nil
        progress = nil
    }

    private func dequeue() -> URL? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    private func runImport(of url: URL) async {
        progress = Progress(fileName: url.lastPathComponent, stage: .preparing, fraction: nil,
                            queued: queue.count, preview: "")
        let task = Task { () -> Result<String, any Error> in
            do {
                return .success(try await self.importRecording(at: url))
            } catch {
                return .failure(error)
            }
        }
        currentImport = task
        let outcome = await task.value
        currentImport = nil
        switch outcome {
        case .success(let noteId):
            NotificationCenter.default.post(name: .scribeNavigate, object: MainSelection.note(noteId))
            AppState.shared.notify("Imported “\(MediaImportFormats.noteTitle(for: url))”")
        case .failure(let error):
            if error is CancellationError {
                Log.app.info("Recording import cancelled.")
            } else {
                Log.app.error("Recording import failed: \(error.localizedDescription, privacy: .private)")
                AppState.shared.report(error)
            }
        }
    }

    // MARK: - One import

    /// Imports one file. Returns the new note's id.
    private func importRecording(at url: URL) async throws -> String {
        let appState = AppState.shared
        guard !appState.isTranscribing, !appState.isStartingSession else {
            throw ScribeMediaImportError.recordingInProgress
        }
        guard MediaImportFormats.isSupported(url) else {
            throw ScribeMediaImportError.unsupportedFile(url.lastPathComponent)
        }
        guard await SpeechRecognizerEngine.checkAuthorization() == .authorized else {
            throw ScribeMediaImportError.speechNotAuthorized
        }
        try Task.checkCancellation()

        let title = MediaImportFormats.noteTitle(for: url)
        let store = appState.transcriptStore
        let note = try NoteStore.shared.createNote(title: title, body: Self.noteHeader(for: url, date: Date()))
        let sessionId = UUID().uuidString
        let directory = SessionAudioStorage.directory(forSessionId: sessionId, root: SessionAudioStorage.defaultRoot())

        let job = ImportJob(
            pipeline: TranscriptionPipeline(speaker: Self.importedSpeaker),
            recorder: SessionAudioRecorder(directory: directory),
            activity: SystemActivityAssertion(reason: "Importing and transcribing a recording")
        )
        self.job = job
        defer { self.job = nil }

        do {
            _ = try store.createSession(title: title, noteId: note.id, id: sessionId, audioDirectory: directory.path)
            let locale = SpeechRecognizerEngine.resolveLocale(UserDefaults.standard.string(forKey: "selectedLanguage"))
            job.wire(onPreview: { [weak self] text in self?.updatePreview(text) })
            try await job.pipeline.start(locale: locale)
            try Task.checkCancellation()

            try await MediaImportDecoder.decode(
                url: url,
                onStart: { [weak self] seconds in await self?.didOpen(duration: seconds) },
                onChunk: { [weak self] samples in
                    guard let self else { throw CancellationError() }
                    try await self.consume(samples)
                }
            )
            try Task.checkCancellation()

            setStage(.finishing, fraction: nil)
            try await job.drain()
            await job.pipeline.stop()
            await Self.finishRecorder(job.recorder)
            if let error = job.error { throw error }
            try Task.checkCancellation()

            setStage(.saving, fraction: nil)
            let pieces = job.segments.map {
                ImportedTranscriptCoalescer.Piece(startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker, text: $0.text)
            }
            let merged = ImportedTranscriptCoalescer.coalesce(pieces)
            guard !merged.isEmpty else { throw ScribeMediaImportError.nothingTranscribed }
            for piece in merged {
                try store.addSegment(sessionId: sessionId, startMs: piece.startMs, endMs: piece.endMs,
                                     speaker: piece.speaker, text: piece.text)
            }
            try finalizeSession(sessionId: sessionId, store: store,
                                durationSeconds: Double(job.fedFrames) / MediaImportDecoder.sampleRate,
                                language: locale.identifier)
        } catch {
            await job.pipeline.stop()
            await Self.finishRecorder(job.recorder)
            job.activity.end()
            // Removes the session, its segments and its audio folder too.
            do {
                try NoteStore.shared.deleteNote(id: note.id)
            } catch {
                Log.app.error("Couldn't remove the note of a failed import: \(error.localizedDescription, privacy: .private)")
            }
            throw error
        }

        // The normal post-recording work (diarization, analysis, summary)
        // and the post-meeting hooks. Keep the Mac awake until it's done.
        let capture = makeDiarizationCapture(sessionId: sessionId, directory: directory, segments: job.segments)
        let work = appState.runPostRecordingProcessing(sessionId: sessionId, diarization: capture)
        MeetingHooks.sessionDidStop(sessionId: sessionId, appState: appState)
        let activity = job.activity
        Task { @MainActor in
            for task in work { await task.value }
            activity.end()
        }
        SemanticIndexScheduler.shared.kick()
        return note.id
    }

    // MARK: - Feeding

    private func didOpen(duration: Double) {
        job?.durationSeconds = duration
        setStage(.transcribing, fraction: 0)
    }

    /// Hands one decoded chunk to the recognizer and the audio file, then
    /// waits while the recognizer is far behind (see `ImportPacing`).
    private func consume(_ samples: [Float]) async throws {
        guard let job else { throw CancellationError() }
        try Task.checkCancellation()
        if let error = job.error { throw error }
        guard let buffer = MediaImportDecoder.makeBuffer(samples) else { return }
        job.recorder.appendSystem(buffer)
        job.pipeline.append(buffer)
        job.fedFrames += samples.count
        setStage(.transcribing, fraction: ImportPacing.fraction(
            fedFrames: job.fedFrames, totalSeconds: job.durationSeconds, sampleRate: MediaImportDecoder.sampleRate))

        var waitedMs = 0
        while ImportPacing.shouldWait(fedMs: job.fedMs, transcribedMs: job.transcribedMs, quietForMs: job.quietForMs),
              waitedMs < ImportPacing.maxWaitMs {
            try await Task.sleep(for: .milliseconds(100))
            waitedMs += 100
        }
    }

    private func setStage(_ stage: Stage, fraction: Double?) {
        guard var current = progress else { return }
        current.stage = stage
        current.fraction = fraction
        current.queued = queue.count
        if current != progress { progress = current }
    }

    private func updatePreview(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var current = progress else { return }
        current.preview = String(trimmed.suffix(140))
        progress = current
    }

    // MARK: - Finishing

    private func finalizeSession(sessionId: String, store: TranscriptStore,
                                 durationSeconds: Double, language: String) throws {
        guard var session = try store.fetchSession(id: sessionId) else { return }
        let seconds = max(0, durationSeconds)
        session.endedAt = session.createdAt.addingTimeInterval(seconds)
        session.durationSeconds = Int(seconds.rounded())
        session.language = language
        try store.updateSession(session)
    }

    /// The diarization job for the imported audio (the whole file is the
    /// "remote" track), or nil when speaker separation is off/unavailable.
    private func makeDiarizationCapture(sessionId: String, directory: URL,
                                        segments: [TranscriptionSegment]) -> SpeakerDiarizationCapture? {
        guard SpeakerDiarizationSettings.isEnabled,
              SpeakerDiarizationModels.source != .unavailable else { return nil }
        let capture = SpeakerDiarizationCapture(sessionId: sessionId, audioDirectory: directory, isScratch: false)
        for segment in segments {
            capture.record(segment, text: segment.text)
        }
        return capture
    }

    /// Closes the audio file off the main actor (it drains the encoder queue).
    private static func finishRecorder(_ recorder: SessionAudioRecorder) async {
        await Task.detached(priority: .utility) {
            recorder.finish()
        }.value
    }

    nonisolated static func noteHeader(for url: URL, date: Date) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "Imported from *\(url.lastPathComponent)* on \(when).\n"
    }
}

// MARK: - Job state

/// Everything one running import owns. Main-actor only.
@MainActor
private final class ImportJob {
    let pipeline: TranscriptionPipeline
    let recorder: SessionAudioRecorder
    let activity: SystemActivityAssertion

    var durationSeconds: Double = 0
    var fedFrames = 0
    private(set) var segments: [TranscriptionSegment] = []
    private(set) var error: Error?
    private var lastSegmentEndMs = 0
    private var lastActivity = ContinuousClock.now

    init(pipeline: TranscriptionPipeline, recorder: SessionAudioRecorder, activity: SystemActivityAssertion) {
        self.pipeline = pipeline
        self.recorder = recorder
        self.activity = activity
    }

    var fedMs: Int { Int(Double(fedFrames) / MediaImportDecoder.sampleRate * 1_000) }
    var transcribedMs: Int { lastSegmentEndMs }
    var quietForMs: Int {
        let elapsed = ContinuousClock.now - lastActivity
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func wire(onPreview: @escaping (String) -> Void) {
        pipeline.onSegment = { [weak self] segment in
            guard let self else { return }
            self.segments.append(segment)
            self.lastSegmentEndMs = max(self.lastSegmentEndMs, segment.endMs)
            self.lastActivity = ContinuousClock.now
            onPreview(segment.text)
        }
        pipeline.onPartialUpdate = { [weak self] text in
            guard let self else { return }
            self.lastActivity = ContinuousClock.now
            if !text.isEmpty { onPreview(text) }
        }
        pipeline.onError = { [weak self] error in
            self?.error = error
        }
    }

    /// Feeds trailing silence so the recognizer finalizes the last words,
    /// then waits until it has been quiet for a moment (it caught up).
    func drain() async throws {
        if let silence = MediaImportDecoder.makeBuffer([Float](repeating: 0, count: Int(MediaImportDecoder.sampleRate * 2))) {
            pipeline.append(silence)
        }
        lastActivity = ContinuousClock.now
        var waitedMs = 0
        while !ImportPacing.isDrained(quietForMs: quietForMs, waitedMs: waitedMs) {
            try await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
            if error != nil { return }
        }
    }
}
