// ScribeiOS/Recording/MobileMediaImporter.swift
//
// Imports audio / video files (Files app, or shared into Scribe) as
// recordings on iPhone / iPad. Reuses the Mac's portable import core:
// `MediaImportDecoder` (16 kHz mono decode of any audio track),
// `MediaImportTranscriptionJob` (recognizer feeding, pacing, draining) and
// `ImportedTranscriptCoalescer`, then the same post-processing as a live
// recording (summary, tasks, note recap). Files are imported one at a time.

import Foundation
import Observation
import Speech

@MainActor
@Observable
final class MobileMediaImporter {

    static let shared = MobileMediaImporter(
        transcriptStore: TranscriptStore.shared,
        noteStore: NoteStore.shared
    )

    struct Progress: Equatable {
        var fileName: String
        /// 0…1 while transcribing; nil while preparing / saving.
        var fraction: Double?
        var queued: Int
        /// Latest recognized text.
        var preview: String
    }

    private(set) var progress: Progress?
    /// A user-facing failure; the UI clears it.
    var errorMessage: String?
    /// The note created by the last successful import.
    private(set) var lastImportedSessionId: String?

    var isImporting: Bool { progress != nil }

    @ObservationIgnored private let transcriptStore: TranscriptStore
    @ObservationIgnored private let noteStore: NoteStore
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var job: MediaImportTranscriptionJob?
    @ObservationIgnored private var currentImport: Task<Result<String, any Error>, Never>?

    init(transcriptStore: TranscriptStore, noteStore: NoteStore) {
        self.transcriptStore = transcriptStore
        self.noteStore = noteStore
    }

    // MARK: - Entry points

    /// Queues files picked in the Files sheet or shared into the app. Each
    /// URL is copied into the app's temporary folder first (security-scoped
    /// access only lasts while we hold it).
    func importFiles(_ urls: [URL]) {
        var accepted: [URL] = []
        for url in urls {
            guard MediaImportFormats.isSupported(url) else {
                errorMessage = ScribeMediaImportError.unsupportedFile(url.lastPathComponent).localizedDescription
                continue
            }
            do {
                accepted.append(try Self.copyToTemporaryFolder(url))
            } catch {
                errorMessage = ScribeMediaImportError.unreadable(error.localizedDescription).localizedDescription
            }
        }
        guard !accepted.isEmpty else { return }
        queue += accepted
        if var current = progress {
            current.queued = queue.count
            progress = current
        }
        if worker == nil {
            worker = Task { [weak self] in await self?.processQueue() }
        }
    }

    /// Cancels the running import and everything queued.
    func cancel() {
        for url in queue { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        queue.removeAll()
        currentImport?.cancel()
    }

    // MARK: - Queue

    private func processQueue() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await runImport(of: next)
            try? FileManager.default.removeItem(at: next.deletingLastPathComponent())
        }
        worker = nil
        progress = nil
    }

    private func runImport(of url: URL) async {
        progress = Progress(fileName: url.lastPathComponent, fraction: nil, queued: queue.count, preview: "")
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
        case .success(let sessionId):
            lastImportedSessionId = sessionId
            MobileRecordingController.shared.runPostProcessing(
                sessionId: sessionId,
                summarize: MobileRecordingSettings.summarize
            )
        case .failure(let error):
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
                Log.app.error("iOS recording import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - One import

    /// Imports one (already copied) file. Returns the new session's id.
    private func importRecording(at url: URL) async throws -> String {
        guard !MobileRecordingController.shared.isActive else {
            throw ScribeMediaImportError.recordingInProgress
        }
        guard await SpeechRecognizerEngine.checkAuthorization() == .authorized else {
            throw MobileAudioCaptureError.speechDenied
        }
        try Task.checkCancellation()

        let background = BackgroundTaskToken(name: "Import a recording into Scribe")
        defer { background.end() }

        let title = MediaImportFormats.noteTitle(for: url)
        let note = try noteStore.createNote(title: title, body: Self.noteHeader(fileName: url.lastPathComponent, date: Date()))
        let sessionId = UUID().uuidString
        let directory = SessionAudioStorage.directory(forSessionId: sessionId, root: SessionAudioStorage.defaultRoot())

        let job = MediaImportTranscriptionJob(
            pipeline: TranscriptionPipeline(speaker: MobileRecordingDefaults.importedSpeakerKey),
            recorder: SessionAudioRecorder(directory: directory)
        )
        self.job = job
        defer { self.job = nil }

        do {
            _ = try transcriptStore.createSession(title: title, noteId: note.id, id: sessionId, audioDirectory: directory.path)
            let locale = SpeechRecognizerEngine.resolveLocale(MobileRecordingSettings.language)
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

            setFraction(nil)
            try await job.drain()
            await job.pipeline.stop()
            await Self.finishRecorder(job.recorder)
            if let error = job.error { throw error }
            try Task.checkCancellation()

            let merged = job.mergedPieces(speaker: nil)
            guard !merged.isEmpty else { throw ScribeMediaImportError.nothingTranscribed }
            for piece in merged {
                try transcriptStore.addSegment(sessionId: sessionId, startMs: piece.startMs, endMs: piece.endMs,
                                               speaker: piece.speaker, text: piece.text)
            }
            if var session = try transcriptStore.fetchSession(id: sessionId) {
                let seconds = max(0, Double(job.fedFrames) / MediaImportDecoder.sampleRate)
                session.endedAt = session.createdAt.addingTimeInterval(seconds)
                session.durationSeconds = Int(seconds.rounded())
                session.language = locale.identifier
                try transcriptStore.updateSession(session)
            }
        } catch {
            await job.pipeline.stop()
            await Self.finishRecorder(job.recorder)
            // Removes the session, its segments and its audio folder too.
            try? noteStore.deleteNote(id: note.id)
            throw error
        }
        return sessionId
    }

    // MARK: - Feeding

    private func didOpen(duration: Double) {
        job?.durationSeconds = duration
        setFraction(0)
    }

    private func consume(_ samples: [Float]) async throws {
        guard let job else { throw CancellationError() }
        try Task.checkCancellation()
        if let error = job.error { throw error }
        guard let buffer = MediaImportDecoder.makeBuffer(samples) else { return }
        job.feed(buffer, frames: samples.count)
        setFraction(ImportPacing.fraction(
            fedFrames: job.fedFrames, totalSeconds: job.durationSeconds, sampleRate: MediaImportDecoder.sampleRate))
        try await job.waitWhileRecognizerIsBehind()
    }

    private func setFraction(_ fraction: Double?) {
        guard var current = progress else { return }
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

    // MARK: - Helpers

    nonisolated static func noteHeader(fileName: String, date: Date) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "Imported from *\(fileName)* on \(when).\n"
    }

    /// Copies `url` (security-scoped when it comes from the Files sheet) into
    /// a fresh folder under the temporary directory, keeping its file name.
    nonisolated static func copyToTemporaryFolder(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private static func finishRecorder(_ recorder: SessionAudioRecorder) async {
        await Task.detached(priority: .utility) {
            recorder.finish()
        }.value
    }
}
