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
/// Models (~22 MB) are not bundled, which keeps the app small: Scribe
/// downloads them once from Hugging Face shortly after installation (and
/// before the first diarization if that didn't happen), into Application
/// Support (``ScribeDiarizerModelManager``). Only model files are downloaded;
/// no audio or text ever leaves the Mac.
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
        /// Downloaded and complete at `root` (the folder FluidAudio loads).
        case installed(URL)
        /// Not downloaded yet; fetched before the first run.
        case download
        /// Not downloaded and downloading is turned off.
        case unavailable
    }

    /// FluidAudio's folder name for the diarizer repository.
    static let repoFolderName = ScribeDiarizerModelRepository.folderName

    /// `~/Library/Application Support/Scribe/DiarizerModels` — the same layout
    /// the iPhone / iPad app uses.
    nonisolated static var layout: ScribeDiarizerModelLayout {
        ScribeDiarizerModelLayout.downloaded(applicationSupport: URL.applicationSupportDirectory)
    }

    nonisolated static var source: Source {
        let layout = layout
        if layout.isInstalledOnDisk() { return .installed(layout.root) }
        return SpeakerDiarizationSettings.allowModelDownload ? .download : .unavailable
    }

    /// Downloads the models if needed (joining a download already running).
    @MainActor
    static func ensureInstalled() async -> Bool {
        await ScribeDiarizerModelManager.shared.ensureInstalled()
    }

    /// After installation (and on later launches until it succeeds): fetch
    /// the models in the background a little after launch, so the first
    /// meeting's speakers are separated without waiting for a download.
    @MainActor
    static func prefetchIfNeeded(delay: Duration = .seconds(20)) {
        guard SpeakerDiarizationSettings.isEnabled,
              SpeakerDiarizationSettings.allowModelDownload,
              !layout.isInstalledOnDisk() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard SpeakerDiarizationSettings.isEnabled,
                  SpeakerDiarizationSettings.allowModelDownload else { return }
            ScribeDiarizerModelManager.shared.download()
        }
    }
}

enum DiarizationModelError: LocalizedError {
    case modelsUnavailable
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .modelsUnavailable:
            return "Speaker separation needs its model, which hasn't been downloaded. Download it in Settings → Vocabulary → Speakers."
        case .downloadFailed:
            return "The speaker model couldn't be downloaded. Scribe will try again; you can also download it in Settings → Vocabulary → Speakers."
        }
    }
}

/// Runs FluidAudio over one audio file (``FluidDiarizationEngine``, shared
/// with the iPhone / iPad app) with the Mac's downloaded models.
enum SpeakerDiarizationRunner {

    static func turns(forAudioAt url: URL) async throws -> [DiarizedSegmentRebuilder.Turn] {
        switch SpeakerDiarizationModels.source {
        case .installed(let root):
            return try await FluidDiarizationEngine.turns(forAudioAt: url, modelsRoot: root, allowNetwork: false)
        case .download:
            guard await SpeakerDiarizationModels.ensureInstalled() else {
                throw DiarizationModelError.downloadFailed
            }
            return try await FluidDiarizationEngine.turns(
                forAudioAt: url, modelsRoot: SpeakerDiarizationModels.layout.root, allowNetwork: false
            )
        case .unavailable:
            throw DiarizationModelError.modelsUnavailable
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

    /// Deletes every scratch folder under `root` (default: ``scratchRoot``)
    /// created before `cutoff`. Called at launch: anything left over is from
    /// a crash, a quit mid-diarization or a deferred job that never ran.
    /// Passing the launch time as `cutoff` keeps the folder of a recording
    /// that started (e.g. auto-record) while this cleanup was still running.
    /// Returns how many entries were removed.
    @discardableResult
    nonisolated static func removeLeftoverScratch(
        in root: URL = scratchRoot,
        createdBefore cutoff: Date = .distantFuture
    ) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        ) else { return 0 }
        var removed = 0
        for entry in entries {
            if let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               created >= cutoff {
                continue
            }
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

            let fileTurns = try await Task.detached(priority: .utility) {
                try await SpeakerDiarizationRunner.turns(forAudioAt: audioURL)
            }.value
            // Turns are timed from the start of system.m4a; segments are on
            // the session clock, where that file starts at its saved offset.
            let offset = SessionAudioTiming.load(from: directory)?.systemStartOffsetSeconds ?? 0
            let turns = fileTurns.map {
                DiarizedSegmentRebuilder.Turn(speakerId: $0.speakerId, start: $0.start + offset, end: $0.end + offset)
            }

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
