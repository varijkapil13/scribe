import CoreML
import FluidAudio
import Foundation

/// On-device speaker diarization for the remote side of a meeting.
///
/// Scribe hears two streams: the mic (always "You") and system audio, which
/// the call app has already mixed from every other participant. Apple's
/// Speech framework doesn't tell voices apart, so after a recording stops we
/// run FluidAudio's offline pyannote pipeline (segmentation + WeSpeaker
/// embeddings + VBx clustering, all Core ML) over the system-audio track and
/// split "Remote" into "Speaker 1…N" (`DiarizedSegmentRebuilder`). Names can
/// then be assigned in the transcript, or suggested from calendar attendees
/// (`SpeakerNameSuggester`).
///
/// Models (~22 MB) ship inside the app (`DiarizerModels/`, fetched at build
/// time by `scripts/fetch-diarizer-models.sh`). Builds without them fall back
/// to a one-time download from Hugging Face if the user allows it. Only model
/// files are downloaded; no audio or text ever leaves the Mac.
enum SpeakerDiarizationSettings {
    static let enabledKey = "speakerDiarizationEnabled"
    static let allowModelDownloadKey = "speakerDiarizationAllowModelDownload"
    static let suggestNamesKey = "speakerDiarizationSuggestNames"

    static var isEnabled: Bool { bool(enabledKey, default: true) }
    static var allowModelDownload: Bool { bool(allowModelDownloadKey, default: true) }
    static var suggestNames: Bool { bool(suggestNamesKey, default: true) }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Where the diarization models come from.
enum SpeakerDiarizationModels {

    enum Source: Equatable {
        /// Shipped inside the app bundle.
        case bundled(URL)
        /// Downloaded on first use into FluidAudio's cache.
        case download
        /// Not bundled and downloading is turned off.
        case unavailable
    }

    /// FluidAudio's folder name for the diarizer repository.
    static let repoFolderName = "speaker-diarization-coreml"

    /// `<App>/Contents/Resources/DiarizerModels`, when it holds the models.
    static var bundledRoot: URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("DiarizerModels", isDirectory: true)
        else { return nil }
        let repo = root.appendingPathComponent(repoFolderName, isDirectory: true)
        return FileManager.default.fileExists(atPath: repo.path) ? root : nil
    }

    static var source: Source {
        if let root = bundledRoot { return .bundled(root) }
        return SpeakerDiarizationSettings.allowModelDownload ? .download : .unavailable
    }
}

enum DiarizationModelError: LocalizedError {
    case modelsUnavailable

    var errorDescription: String? {
        "Speaker separation needs its model, which isn't bundled with this build. Allow the one-time model download in Settings → Vocabulary → Speakers."
    }
}

/// Runs FluidAudio over one audio file. Everything is local to the call, so
/// the non-Sendable diarizer never crosses an isolation boundary.
enum SpeakerDiarizationRunner {

    static func turns(forAudioAt url: URL) async throws -> [DiarizedSegmentRebuilder.Turn] {
        let directory: URL?
        switch SpeakerDiarizationModels.source {
        case .bundled(let root):
            // Never reach for the network when the models ship with the app.
            ModelHub.offlineMode = true
            directory = root
        case .download:
            ModelHub.offlineMode = false
            directory = nil
        case .unavailable:
            throw DiarizationModelError.modelsUnavailable
        }

        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: directory)
        let result = try await manager.process(url)
        return result.segments.map { segment in
            DiarizedSegmentRebuilder.Turn(
                speakerId: segment.speakerId,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)
            )
        }
    }
}

/// Per-recording state: where the audio goes and the raw remote recognizer
/// results needed to split coalesced segments.
@MainActor
final class SpeakerDiarizationCapture {
    let sessionId: String
    /// Folder the session's audio is written to.
    let audioDirectory: URL
    /// True when the audio was only kept for diarization (retention off) and
    /// should be deleted afterwards.
    let isScratch: Bool
    private(set) var pieces: [DiarizedSegmentRebuilder.Piece] = []

    init(sessionId: String, audioDirectory: URL, isScratch: Bool) {
        self.sessionId = sessionId
        self.audioDirectory = audioDirectory
        self.isScratch = isScratch
    }

    /// Records a finalized remote recognizer result.
    func record(_ segment: TranscriptionSegment, text: String) {
        let length = max(0, segment.endMs - segment.startMs)
        pieces.append(.init(
            startMs: segment.sessionOffsetMs,
            endMs: segment.sessionOffsetMs + length,
            text: text
        ))
    }

    /// Parent of every per-session scratch folder.
    nonisolated static var scratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeDiarization", isDirectory: true)
    }

    /// A temporary folder for audio kept only for diarization.
    nonisolated static func scratchDirectory(for sessionId: String) -> URL {
        scratchRoot.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// Deletes every scratch folder under `root` (default: ``scratchRoot``).
    /// Called at launch, when no recording can be using one: anything left
    /// over is from a crash, a quit mid-diarization or a deferred job that
    /// never ran. Returns how many entries were removed.
    @discardableResult
    nonisolated static func removeLeftoverScratch(in root: URL = scratchRoot) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return 0 }
        var removed = 0
        for entry in entries {
            do {
                try fileManager.removeItem(at: entry)
                removed += 1
            } catch {
                Log.speech.error("Couldn't remove diarization scratch \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }
}

/// Glue between a finished recording and the diarizer.
@MainActor
enum SpeakerDiarizationCoordinator {

    /// Whether a recording should capture audio for diarization, and where.
    /// `retainedDirectory` is the session's retained-audio folder, if any.
    static func makeCapture(
        sessionId: String,
        retainedDirectory: URL?,
        capturesSystemAudio: Bool
    ) -> SpeakerDiarizationCapture? {
        guard capturesSystemAudio, SpeakerDiarizationSettings.isEnabled,
              SpeakerDiarizationModels.source != .unavailable else { return nil }
        if let retainedDirectory {
            return SpeakerDiarizationCapture(sessionId: sessionId, audioDirectory: retainedDirectory, isScratch: false)
        }
        return SpeakerDiarizationCapture(
            sessionId: sessionId,
            audioDirectory: SpeakerDiarizationCapture.scratchDirectory(for: sessionId),
            isScratch: true
        )
    }

    /// One finished recording waiting to be diarized.
    struct Job: Sendable {
        let sessionId: String
        let pieces: [DiarizedSegmentRebuilder.Piece]
        let directory: URL
        let isScratch: Bool
    }

    /// Jobs deferred because the Mac was hot or in Low Power Mode.
    private static var deferredJobs: [Job] = []
    private static var deferredStore: TranscriptStore?
    private static var conditionObservers: [NSObjectProtocol] = []
    private static var drainTask: Task<Void, Never>?

    /// Runs diarization in the background once the recording's files are
    /// closed, applies the result, and suggests names. Failures only log —
    /// the transcript simply stays "Remote".
    ///
    /// When the Mac is thermally stressed or in Low Power Mode the job is
    /// queued and runs once conditions improve (see ``HeavyWorkConditions``).
    ///
    /// - Returns: The task doing the work now (finishes immediately when the
    ///   job was deferred), so the caller can keep the Mac awake until it ends.
    @discardableResult
    static func sessionDidStop(_ capture: SpeakerDiarizationCapture, store: TranscriptStore) -> Task<Void, Never> {
        let job = Job(
            sessionId: capture.sessionId,
            pieces: capture.pieces,
            directory: capture.audioDirectory,
            isScratch: capture.isScratch
        )
        if HeavyWorkConditions.shouldDeferNow() {
            Log.speech.info("Deferring speaker diarization for session \(job.sessionId, privacy: .public): \(HeavyWorkConditions.describeCurrent(), privacy: .public).")
            deferredJobs.append(job)
            deferredStore = store
            observeConditions()
            return Task {}
        }
        return Task { @MainActor in
            await SpeakerDiarizationCoordinator.run(job, store: store)
        }
    }

    /// Diarizes one recording. Deletes scratch audio afterwards either way.
    private static func run(_ job: Job, store: TranscriptStore) async {
        let sessionId = job.sessionId
        let directory = job.directory
        let isScratch = job.isScratch
        let audioURL = SessionAudioStorage.systemFileURL(in: directory)
        defer {
            if isScratch { try? FileManager.default.removeItem(at: directory) }
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        do {
            let stored = try store.fetchDiarizableSegments(sessionId: sessionId)
            guard !stored.isEmpty else { return }

            let turns = try await Task.detached(priority: .utility) {
                try await SpeakerDiarizationRunner.turns(forAudioAt: audioURL)
            }.value

            let changes = DiarizedSegmentRebuilder.changes(stored: stored, pieces: job.pieces, turns: turns)
            guard !changes.isEmpty else {
                Log.speech.info("Diarization found a single remote speaker; transcript unchanged.")
                return
            }
            try store.applyDiarization(changes, sessionId: sessionId)
            Log.speech.info("Diarization split remote audio for session \(sessionId, privacy: .public).")

            if SpeakerDiarizationSettings.suggestNames {
                await SpeakerNameSuggester.applySuggestions(sessionId: sessionId, store: store)
            }
            NotificationCenter.default.post(name: .scribeSpeakersDidChange, object: sessionId)
        } catch {
            Log.speech.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Watches thermal state and Low Power Mode while jobs are deferred.
    private static func observeConditions() {
        guard conditionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SpeakerDiarizationCoordinator.drainDeferredIfPossible() }
            }
            conditionObservers.append(observer)
        }
    }

    /// Runs deferred jobs one after another once conditions allow.
    private static func drainDeferredIfPossible() {
        guard drainTask == nil, !deferredJobs.isEmpty else { return }
        guard !HeavyWorkConditions.shouldDeferNow() else { return }
        guard let store = deferredStore else { return }
        let count = deferredJobs.count
        Log.speech.info("Running \(count) deferred speaker diarization job(s).")
        drainTask = Task { @MainActor in
            while !SpeakerDiarizationCoordinator.deferredJobs.isEmpty, !HeavyWorkConditions.shouldDeferNow() {
                let job = SpeakerDiarizationCoordinator.deferredJobs.removeFirst()
                await SpeakerDiarizationCoordinator.run(job, store: store)
            }
            SpeakerDiarizationCoordinator.drainTask = nil
            if SpeakerDiarizationCoordinator.deferredJobs.isEmpty {
                for observer in SpeakerDiarizationCoordinator.conditionObservers {
                    NotificationCenter.default.removeObserver(observer)
                }
                SpeakerDiarizationCoordinator.conditionObservers.removeAll()
                SpeakerDiarizationCoordinator.deferredStore = nil
            }
        }
    }
}

extension Notification.Name {
    /// Posted (object: session id) when diarization or name suggestions
    /// changed a session's speakers, so open transcript views reload names.
    static let scribeSpeakersDidChange = Notification.Name("scribe.speakersDidChange")
}
