// ScribeiOS/Diarization/IOSDiarizationScheduler.swift
//
// Speaker separation after an iPhone / iPad recording (or import) finishes:
// FluidAudio's offline diarizer (Scribe/Diarization/Portable) over the
// recording's audio, then the Mac's `DiarizedSegmentRebuilder` /
// `applyDiarization` split "In person" into "Speaker 1…N", the Foundation
// Models `SpeakerNameSuggester` proposes names (calendar attendees, "thanks,
// Priya"), and the meeting note's transcript is rewritten with them.
//
// It runs right away only when that's cheap (`MobileDiarizationPolicy`: on
// power or > 30 % battery, Low Power Mode off, not thermally serious).
// Otherwise the job — persisted in Application Support so it survives the app
// being killed — waits for a `BGProcessingTask` (on the charger for battery
// deferrals) or for conditions to improve while the app is open.

import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Reads the device's battery / thermal state for the policy.
@MainActor
enum IOSDiarizationDeviceConditions {
    static func current() -> MobileDiarizationConditions {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let batteryState = device.batteryState
        let info = ProcessInfo.processInfo
        return MobileDiarizationConditions(
            isOnExternalPower: batteryState == .charging || batteryState == .full,
            batteryLevel: MobileDiarizationPolicy.batteryLevel(fromDeviceLevel: device.batteryLevel),
            thermalState: info.thermalState,
            isLowPowerMode: info.isLowPowerModeEnabled
        )
    }
}

/// Carries a `BGTask` (not Sendable) onto the main actor. Only touched there.
final class IOSBackgroundTaskBox: @unchecked Sendable {
    let task: BGTask
    var isCompleted = false

    nonisolated init(task: BGTask) {
        self.task = task
    }
}

@MainActor
@Observable
final class IOSDiarizationScheduler {

    /// Listed under BGTaskSchedulerPermittedIdentifiers (project.yml).
    nonisolated static let backgroundTaskIdentifier = "com.varij.scribe.diarization"

    static let shared = IOSDiarizationScheduler(
        transcriptStore: TranscriptStore.shared,
        queue: MobileDiarizationQueue(
            directory: MobileDiarizationQueue.defaultDirectory(applicationSupport: URL.applicationSupportDirectory)
        ),
        models: IOSDiarizationModelManager.shared
    )

    /// The session being diarized right now.
    private(set) var runningSessionId: String?
    /// Why queued sessions are waiting (session id → reason).
    private(set) var waitingReasons: [String: String] = [:]
    /// Sessions with a queued job.
    private(set) var queuedSessionIds: Set<String> = []

    private let transcriptStore: TranscriptStore
    private let queue: MobileDiarizationQueue
    private let models: IOSDiarizationModelManager

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask: IOSBackgroundTaskBox?
    /// Sessions the user asked to separate now (battery deferral ignored).
    @ObservationIgnored private var userRequested: Set<String> = []

    init(transcriptStore: TranscriptStore, queue: MobileDiarizationQueue, models: IOSDiarizationModelManager) {
        self.transcriptStore = transcriptStore
        self.queue = queue
        self.models = models
    }

    // MARK: - Lifecycle

    /// Called once from `ScribeiOSBootstrap.run()` — the background task
    /// must be registered before launch finishes.
    func start() {
        guard !didStart else { return }
        didStart = true
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: DispatchQueue.main,
            launchHandler: Self.makeLaunchHandler()
        )
        if !registered {
            Log.speech.error("Couldn't register the speaker separation background task.")
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        observeConditions()
        if !IOSDiarizationSettings.isEnabled { discardQueuedJobs() }
        removeOrphanScratchAudio()
        refreshQueued()
        drainIfPossible()
    }

    // MARK: - Entry points

    /// Folder for audio kept only for diarization (Keep audio off), or nil
    /// when speaker separation is off.
    func scratchAudioDirectory(forSessionId sessionId: String) -> URL? {
        guard IOSDiarizationSettings.isEnabled else { return nil }
        let directory = MobileDiarizationQueue.scratchAudioDirectory(
            applicationSupport: URL.applicationSupportDirectory, sessionId: sessionId
        )
        Self.excludeFromBackup(directory.deletingLastPathComponent())
        return directory
    }

    /// A live recording finished. `kept` is false when it was discarded.
    func recordingDidFinish(
        sessionId: String,
        audioDirectory: URL?,
        isScratch: Bool,
        pieces: [MobileDiarizationJob.Piece],
        kept: Bool
    ) {
        // Jobs queued earlier wait while a recording runs (see `drain`).
        defer { drainIfPossible() }
        guard let audioDirectory else { return }
        guard kept, IOSDiarizationSettings.isEnabled else {
            if isScratch { try? FileManager.default.removeItem(at: audioDirectory) }
            return
        }
        enqueue(MobileDiarizationJob(
            sessionId: sessionId,
            audioDirectoryPath: audioDirectory.path,
            audioFileName: SessionAudioStorage.micFileName,
            isScratch: isScratch,
            speakerKeys: [MobileRecordingDefaults.speakerKey],
            pieces: pieces,
            createdAt: Date(),
            failureCount: 0
        ))
    }

    /// An audio / video import finished (its audio is always retained, as
    /// `system.m4a`).
    func importDidFinish(sessionId: String, audioDirectory: URL, pieces: [MobileDiarizationJob.Piece]) {
        guard IOSDiarizationSettings.isEnabled else { return }
        enqueue(MobileDiarizationJob(
            sessionId: sessionId,
            audioDirectoryPath: audioDirectory.path,
            audioFileName: SessionAudioStorage.systemFileName,
            isScratch: false,
            speakerKeys: [MobileRecordingDefaults.importedSpeakerKey],
            pieces: pieces,
            createdAt: Date(),
            failureCount: 0
        ))
    }

    /// "Separate Speakers" on a recording with retained audio. Ignores the
    /// battery rules (not the thermal one). Returns false when the session
    /// has no audio to work on.
    @discardableResult
    func separateSpeakersNow(sessionId: String) -> Bool {
        guard let session = try? transcriptStore.fetchSession(id: sessionId) else { return false }
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        guard let directory = SessionAudioLocator.directory(
            storedPath: session.audioDirectory,
            sessionId: session.id,
            currentRoot: SessionAudioStorage.defaultRoot(),
            fileExists: exists
        ), let file = SessionAudioLocator.playableFile(in: directory, fileExists: exists) else { return false }
        userRequested.insert(sessionId)
        enqueue(MobileDiarizationJob(
            sessionId: sessionId,
            audioDirectoryPath: directory.path,
            audioFileName: file.lastPathComponent,
            isScratch: false,
            speakerKeys: [MobileRecordingDefaults.speakerKey, MobileRecordingDefaults.importedSpeakerKey],
            pieces: [],
            createdAt: Date(),
            failureCount: 0
        ))
        return true
    }

    /// Status line for the recording screen, or nil when nothing is pending.
    func status(for sessionId: String) -> String? {
        if runningSessionId == sessionId { return "Separating speakers on this device…" }
        if let reason = waitingReasons[sessionId] { return reason }
        if queuedSessionIds.contains(sessionId) { return "Waiting to separate speakers" }
        return nil
    }

    /// Speaker separation was turned off: drop queued jobs and the audio
    /// kept only for them (retained recordings are untouched).
    func discardQueuedJobs() {
        drainTask?.cancel()
        for job in queue.pending() where job.sessionId != runningSessionId {
            finish(job)
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    }

    // MARK: - Queue

    private func enqueue(_ job: MobileDiarizationJob) {
        do {
            try queue.save(job)
        } catch {
            Log.speech.error("Couldn't queue speaker separation: \(error.localizedDescription, privacy: .public)")
            return
        }
        refreshQueued()
        // Safety net: if iOS suspends the app mid-run, a background task on
        // the charger finishes the job even if the app isn't opened again.
        scheduleBackgroundTask(requiresExternalPower: true, requiresNetwork: false, earliest: nil)
        drainIfPossible()
    }

    private func refreshQueued() {
        queuedSessionIds = Set(queue.pending().map(\.sessionId))
        waitingReasons = waitingReasons.filter { queuedSessionIds.contains($0.key) }
    }

    /// Runs queued jobs one after another while conditions allow.
    func drainIfPossible() {
        guard drainTask == nil, IOSDiarizationSettings.isEnabled, !queue.pending().isEmpty else { return }
        drainTask = Task(priority: .utility) { @MainActor in
            await self.drain()
            self.drainTask = nil
            self.refreshQueued()
            if self.queuedSessionIds.isEmpty {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            }
            self.completeBackgroundTaskIfIdle()
        }
    }

    private func drain() async {
        var skipped = Set<String>()
        while !Task.isCancelled {
            // Never compete with a live recording (or one still being
            // finalized) for the CPU / Neural Engine; `recordingDidFinish`
            // drains again once it's done.
            if MobileRecordingController.shared.isActive { break }

            let candidates = queue.pending().filter { !skipped.contains($0.sessionId) }
            // "Separate Speakers" jobs first, so they aren't stuck behind a
            // job the battery rules defer.
            guard let job = candidates.first(where: { userRequested.contains($0.sessionId) }) ?? candidates.first
            else { break }

            if case .deferred(let deferral) = MobileDiarizationPolicy.decide(IOSDiarizationDeviceConditions.current()),
               !(userRequested.contains(job.sessionId) && deferral != .thermal) {
                Log.speech.info("Deferring speaker separation: \(deferral.label, privacy: .public).")
                markAllWaiting(deferral.label)
                scheduleBackgroundTask(
                    requiresExternalPower: deferral.requiresExternalPower,
                    requiresNetwork: false,
                    earliest: MobileDiarizationPolicy.earliestRetry(for: deferral, now: Date())
                )
                break
            }

            // Re-read the disk: FluidAudio deletes the models folder when a
            // load fails, which would otherwise leave a stale "installed".
            models.refresh()
            if !models.isInstalled {
                waitingReasons[job.sessionId] = "Downloading the speaker model…"
                let installed = await models.ensureInstalled()
                if Task.isCancelled { break }
                if !installed {
                    let reason: String
                    if case .failed(let message) = models.state { reason = message } else { reason = "Waiting to download the speaker model" }
                    markAllWaiting(reason)
                    scheduleBackgroundTask(requiresExternalPower: false, requiresNetwork: true, earliest: nil)
                    break
                }
            }

            waitingReasons[job.sessionId] = nil
            runningSessionId = job.sessionId
            let outcome = await run(job)
            runningSessionId = nil

            switch outcome {
            case .finished:
                finish(job)
            case .interrupted:
                if !IOSDiarizationSettings.isEnabled {
                    finish(job)
                    return
                }
                // Stays queued; the background task picks it up.
                scheduleBackgroundTask(requiresExternalPower: true, requiresNetwork: false, earliest: nil)
                return
            case .failed(let message):
                models.refresh()
                var failed = job
                failed.failureCount += 1
                if failed.failureCount >= MobileDiarizationJob.maximumFailures {
                    Log.speech.error("Giving up on speaker separation for \(job.sessionId, privacy: .public): \(message, privacy: .public)")
                    finish(job)
                } else {
                    try? queue.save(failed)
                    waitingReasons[job.sessionId] = "Speaker separation failed — will retry"
                    skipped.insert(job.sessionId)
                }
            }
        }
    }

    private enum RunOutcome {
        case finished
        case interrupted
        case failed(String)
    }

    /// Diarizes one job and applies the result.
    private func run(_ job: MobileDiarizationJob) async -> RunOutcome {
        let background = BackgroundTaskToken(name: "Separate speakers")
        defer { background.end() }
        let sessionId = job.sessionId
        let audioURL = job.audioFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return .finished }
        do {
            let stored = try transcriptStore.fetchDiarizableSegments(
                sessionId: sessionId, speakerKeys: Set(job.speakerKeys)
            )
            guard !stored.isEmpty else { return .finished }

            // Detached so the Core ML work never runs on the main actor.
            let modelsRoot = models.layout.root
            let work = Task.detached(priority: .utility) {
                try await FluidDiarizationEngine.turns(forAudioAt: audioURL, modelsRoot: modelsRoot, allowNetwork: false)
            }
            let fileTurns = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            // FluidAudio may finish despite a cancellation (background time
            // expired): keep the result rather than redoing the work, unless
            // speaker separation was turned off meanwhile.
            if !IOSDiarizationSettings.isEnabled { return .interrupted }
            let turns = job.turnsOnSessionClock(fileTurns, timing: SessionAudioTiming.load(from: job.audioDirectory))
            // Re-read: the user may have reassigned lines while this ran.
            let current = try transcriptStore.fetchDiarizableSegments(
                sessionId: sessionId, speakerKeys: Set(job.speakerKeys)
            )
            let changes = DiarizedSegmentRebuilder.changes(stored: current, pieces: job.rebuilderPieces, turns: turns)
            guard !changes.isEmpty else {
                Log.speech.info("Speaker separation found a single speaker; transcript unchanged.")
                return .finished
            }
            try transcriptStore.applyDiarization(changes, sessionId: sessionId)
            Log.speech.info("Speaker separation split session \(sessionId, privacy: .public).")

            if IOSDiarizationSettings.suggestNames {
                await SpeakerNameSuggester.applySuggestions(sessionId: sessionId, store: transcriptStore)
            }
            NotificationCenter.default.post(name: .scribeSpeakersDidChange, object: sessionId)
            await rewriteMeetingNote(sessionId: sessionId)
            return .finished
        } catch is CancellationError {
            return .interrupted
        } catch {
            if Task.isCancelled { return .interrupted }
            Log.speech.error("Speaker separation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Rewrites the note's transcript / highlights with the new speakers,
    /// once the recording's own post-processing (summary) is done.
    private func rewriteMeetingNote(sessionId: String) async {
        let controller = MobileRecordingController.shared
        var waitedSeconds = 0
        while controller.processingSessionIds.contains(sessionId), waitedSeconds < 600, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            waitedSeconds += 1
        }
        controller.runPostProcessing(sessionId: sessionId, summarize: false)
    }

    private func finish(_ job: MobileDiarizationJob) {
        queue.remove(sessionId: job.sessionId)
        userRequested.remove(job.sessionId)
        waitingReasons[job.sessionId] = nil
        if job.isScratch {
            try? FileManager.default.removeItem(at: job.audioDirectory)
        }
        refreshQueued()
    }

    private func markAllWaiting(_ reason: String) {
        for job in queue.pending() where job.sessionId != runningSessionId {
            waitingReasons[job.sessionId] = reason
        }
    }

    /// Scratch audio folders whose job is gone (crash, or the recording
    /// was discarded while the app was killed).
    private func removeOrphanScratchAudio() {
        let root = MobileDiarizationQueue.scratchAudioDirectory(
            applicationSupport: URL.applicationSupportDirectory, sessionId: "_"
        ).deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let queued = Set(queue.pending().map(\.sessionId))
        let recording = MobileRecordingController.shared.sessionId
        for entry in entries where !queued.contains(entry.lastPathComponent) && entry.lastPathComponent != recording {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Conditions

    private func observeConditions() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            UIDevice.batteryStateDidChangeNotification,
            UIDevice.batteryLevelDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { IOSDiarizationScheduler.shared.drainIfPossible() }
            }
            observers.append(observer)
        }
    }

    // MARK: - Background task

    private func scheduleBackgroundTask(requiresExternalPower: Bool, requiresNetwork: Bool, earliest: Date?) {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresExternalPower = requiresExternalPower
        request.requiresNetworkConnectivity = requiresNetwork
        request.earliestBeginDate = earliest
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the Simulator; on a device it means the identifier
            // or the `processing` background mode is missing.
            Log.speech.error("Couldn't schedule speaker separation: \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate func handle(_ box: IOSBackgroundTaskBox) {
        if let previous = backgroundTask, !previous.isCompleted {
            complete(previous, success: true)
        }
        backgroundTask = box
        box.task.expirationHandler = Self.makeExpirationHandler(box)
        drainIfPossible()
        completeBackgroundTaskIfIdle()
    }

    fileprivate func backgroundTimeExpired(_ box: IOSBackgroundTaskBox) {
        drainTask?.cancel()
        if !queue.pending().isEmpty {
            scheduleBackgroundTask(requiresExternalPower: true, requiresNetwork: false, earliest: nil)
        }
        complete(box, success: false)
    }

    private func completeBackgroundTaskIfIdle() {
        guard drainTask == nil, let box = backgroundTask, !box.isCompleted else { return }
        complete(box, success: true)
    }

    private func complete(_ box: IOSBackgroundTaskBox, success: Bool) {
        guard !box.isCompleted else { return }
        box.isCompleted = true
        box.task.setTaskCompleted(success: success)
        if backgroundTask === box { backgroundTask = nil }
    }

    // Built outside the main actor: BackgroundTasks calls these on its own
    // queues, so they must not be inferred main-actor isolated.

    nonisolated private static func makeLaunchHandler() -> @Sendable (BGTask) -> Void {
        { task in
            let box = IOSBackgroundTaskBox(task: task)
            Task { @MainActor in
                IOSDiarizationScheduler.shared.handle(box)
            }
        }
    }

    nonisolated private static func makeExpirationHandler(_ box: IOSBackgroundTaskBox) -> @Sendable () -> Void {
        {
            Task { @MainActor in
                IOSDiarizationScheduler.shared.backgroundTimeExpired(box)
            }
        }
    }

    nonisolated private static func excludeFromBackup(_ directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ScribeDiarizerModelStorage.excludeFromBackup(directory)
        } catch {
            Log.speech.error("Couldn't prepare the speaker separation folder: \(error.localizedDescription, privacy: .public)")
        }
    }
}
