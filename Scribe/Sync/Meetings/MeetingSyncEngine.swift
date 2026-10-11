import Foundation

/// Per-round settings, read on the main actor by the scheduler.
struct MeetingSyncRoundOptions: Sendable, Equatable {
    var deviceKind: MeetingDeviceKind
    /// "Sync recording audio" is on.
    var syncAudio: Bool
    var maxAudioFileBytes: Int64
    var maxAudioSessionBytes: Int64
    var now: Date

    init(
        deviceKind: MeetingDeviceKind,
        syncAudio: Bool,
        maxAudioFileBytes: Int64,
        maxAudioSessionBytes: Int64,
        now: Date
    ) {
        self.deviceKind = deviceKind
        self.syncAudio = syncAudio
        self.maxAudioFileBytes = maxAudioFileBytes
        self.maxAudioSessionBytes = maxAudioSessionBytes
        self.now = now
    }
}

/// What one round did (Sendable, for the scheduler / UI / tests).
struct MeetingSyncRoundReport: Sendable, Equatable {
    var importedSessionIds: [String] = []
    var deletedSessionIds: [String] = []
    /// Sessions whose audio became available in iCloud (nothing else changed).
    var audioAvailableSessionIds: [String] = []
    var pushedSessions = 0
    var pushedDeletions = 0
    var uploadedAudioFiles = 0
    var failures = 0

    /// Local sessions this round created, changed or removed.
    var changedSessionIds: [String] { importedSessionIds + deletedSessionIds + audioAvailableSessionIds }
}

enum MeetingSyncEngineError: Error, Equatable {
    case noRemoteAudio
}

/// Runs meeting sync rounds: pull the `Meetings` zone's changes and merge
/// them (last-writer-wins on the session's `updatedAt`, tombstones), then
/// push finished local sessions with unpushed changes and unpushed
/// deletions. An actor, so rounds (and audio downloads) never overlap and
/// the database / encoding work stays off the main actor.
///
/// ⚠️ DEVICE-VALIDATION REQUIRED for the live CloudKit path; this logic is
/// unit-tested against a fake `MeetingCloudServicing`.
actor MeetingSyncEngine {

    nonisolated static let maxPagesPerRound = 100
    /// Pushed tombstones are kept this long, then pruned.
    nonisolated static let tombstoneRetention: TimeInterval = 180 * 24 * 60 * 60

    private let local: MeetingSyncLocalStore
    private let cloud: any MeetingCloudServicing
    private var zoneReady = false

    init(local: MeetingSyncLocalStore, cloud: any MeetingCloudServicing) {
        self.local = local
        self.cloud = cloud
    }

    // MARK: - Round

    func runRound(_ options: MeetingSyncRoundOptions) async throws -> MeetingSyncRoundReport {
        let deviceId = try local.deviceId()
        try await prepareZone()
        var report = MeetingSyncRoundReport()
        do {
            try await pull(deviceId: deviceId, report: &report)
        } catch MeetingCloudServiceError.changeTokenExpired {
            // Start over from the beginning of the zone (imports are idempotent).
            try local.setChangeToken(nil)
            try await pull(deviceId: deviceId, report: &report)
        } catch MeetingCloudServiceError.zoneMissing {
            // The zone was removed (iCloud data cleared). Recreate it; local
            // meetings stay as they are.
            zoneReady = false
            try local.setChangeToken(nil)
            try await prepareZone()
            try await pull(deviceId: deviceId, report: &report)
        }
        try await push(options, deviceId: deviceId, report: &report)
        try local.pruneTombstones(before: options.now.addingTimeInterval(-Self.tombstoneRetention))
        return report
    }

    private func prepareZone() async throws {
        guard !zoneReady else { return }
        try await cloud.ensureZone()
        zoneReady = true
    }

    // MARK: - Pull

    private func pull(deviceId: String, report: inout MeetingSyncRoundReport) async throws {
        var token = try local.changeToken()
        var sessions: [String: MeetingSessionSnapshot] = [:]
        var transcripts: [String: MeetingTranscriptPayload] = [:]
        var removed: Set<String> = []
        var pages = 0
        while true {
            let batch = try await cloud.fetchChanges(since: token)
            for snapshot in batch.sessions {
                if let seen = sessions[snapshot.id], seen.updatedAt >= snapshot.updatedAt { continue }
                sessions[snapshot.id] = snapshot
                removed.remove(snapshot.id)
            }
            for (sessionId, transcript) in batch.transcripts {
                transcripts[sessionId] = transcript
            }
            for sessionId in batch.removedSessionIds {
                removed.insert(sessionId)
                sessions[sessionId] = nil
            }
            token = batch.token
            pages += 1
            if !batch.moreComing || pages >= Self.maxPagesPerRound { break }
        }

        var failures = 0
        let ordered = sessions.values.sorted { $0.createdAt < $1.createdAt }
        for snapshot in ordered {
            do {
                try await apply(snapshot, bundled: transcripts[snapshot.id], deviceId: deviceId, report: &report)
            } catch {
                failures += 1
                Log.storage.error("Meeting sync couldn't apply a remote meeting: \(error.localizedDescription, privacy: .public)")
            }
        }
        for sessionId in removed.sorted() {
            do {
                if try applyRemoval(sessionId: sessionId) {
                    report.deletedSessionIds.append(sessionId)
                }
            } catch {
                failures += 1
                Log.storage.error("Meeting sync couldn't remove a meeting: \(error.localizedDescription, privacy: .public)")
            }
        }
        report.failures += failures
        // Advance only when everything applied: a failed import is retried
        // from the same token next round (imports are idempotent).
        if failures == 0 {
            try local.setChangeToken(token)
        }
    }

    private func apply(
        _ snapshot: MeetingSessionSnapshot,
        bundled: MeetingTranscriptPayload?,
        deviceId: String,
        report: inout MeetingSyncRoundReport
    ) async throws {
        // Only finished recordings are ever pushed; a live version without
        // an end would import as a recording "in progress" here, which then
        // never syncs again (and blocks later versions). Ignore it.
        guard snapshot.isDeleted || snapshot.endedAt != nil else { return }
        let localState = try local.localState(sessionId: snapshot.id)
        let remoteSide = MeetingSyncMergePolicy.Side(updatedAt: snapshot.updatedAt, isDeleted: snapshot.isDeleted)
        switch MeetingSyncMergePolicy.resolve(local: localState?.side, remote: remoteSide) {
        case .keepLocal:
            // Audio uploaded later (backfill) re-saves the record with its
            // old clock, so it ties here; still learn that it's in iCloud.
            if let localState, !localState.side.isDeleted, !snapshot.isDeleted, !snapshot.audioFiles.isEmpty,
               try local.mergeRemoteAudio(sessionId: snapshot.id, files: snapshot.audioFiles) {
                report.audioAvailableSessionIds.append(snapshot.id)
            }
            return
        case .rememberTombstone:
            try local.rememberRemoteTombstone(sessionId: snapshot.id, deletedAt: snapshot.updatedAt)
        case .applyRemoteDelete:
            try local.applyRemoteDeletion(sessionId: snapshot.id, deletedAt: snapshot.updatedAt)
            report.deletedSessionIds.append(snapshot.id)
        case .applyRemote:
            var transcript = bundled
            if transcript == nil {
                // Fetch when the remote transcript differs from ours, or when
                // unpushed local edits lose to the newer remote version.
                let differs = MeetingSyncMergePolicy.needsTranscript(
                    remoteHash: snapshot.transcriptHash,
                    localHash: localState?.transcriptHash
                )
                let localEditsLose = (localState?.isDirty ?? false) && snapshot.transcriptHash != nil
                if differs || localEditsLose {
                    transcript = try await cloud.fetchTranscript(sessionId: snapshot.id)
                }
            }
            try local.importRemote(snapshot, transcript: transcript, localDeviceId: deviceId)
            report.importedSessionIds.append(snapshot.id)
        }
    }

    /// A `MeetingSession` record vanished from the zone (no tombstone, no
    /// timestamp). Delete the local copy unless it has unpushed edits (those
    /// re-create the record on the push half).
    private func applyRemoval(sessionId: String) throws -> Bool {
        guard let state = try local.localState(sessionId: sessionId),
              !state.side.isDeleted, !state.side.isInProgress, !state.isDirty else { return false }
        try local.applyRemoteDeletion(sessionId: sessionId, deletedAt: Date())
        return true
    }

    // MARK: - Push

    private func push(_ options: MeetingSyncRoundOptions, deviceId: String, report: inout MeetingSyncRoundReport) async throws {
        for tombstone in try local.pendingTombstones() {
            let saved = try await cloud.saveSession(
                .tombstone(id: tombstone.sessionId, deletedAt: tombstone.deletedAt),
                transcript: nil
            )
            guard saved else {
                report.failures += 1
                continue
            }
            do {
                try await cloud.deleteSessionPayloads(sessionId: tombstone.sessionId)
            } catch {
                // The tombstone already hides the meeting everywhere; leftover
                // payload records only cost space.
                Log.storage.error("Meeting sync couldn't remove a deleted meeting's files: \(error.localizedDescription, privacy: .public)")
            }
            try local.markTombstonePushed(sessionId: tombstone.sessionId)
            report.pushedDeletions += 1
        }

        let pending = try local.pendingPushes(
            includeAudioBackfill: options.syncAudio,
            localDevice: options.deviceKind,
            localDeviceId: deviceId
        )
        for item in pending {
            var snapshot = item.snapshot
            var audioDone: Bool?
            if options.syncAudio, item.isLocalRecording, !item.audioPushed, let path = item.audioDirectory {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                let present = MeetingAudioSyncPolicy.localFiles(in: directory)
                let selected = MeetingAudioSyncPolicy.selectUploads(
                    present,
                    maxFile: options.maxAudioFileBytes,
                    maxTotal: options.maxAudioSessionBytes
                )
                if !selected.isEmpty {
                    let uploads = selected.map {
                        MeetingAudioUpload(info: $0, fileURL: directory.appendingPathComponent($0.fileName))
                    }
                    let uploaded = try await cloud.uploadAudio(sessionId: snapshot.id, files: uploads)
                    snapshot.audioFiles = Self.merged(snapshot.audioFiles, uploaded)
                    report.uploadedAudioFiles += uploaded.count
                    audioDone = uploaded.count == selected.count
                } else if !present.isEmpty {
                    // Too large to sync: don't re-check it every round.
                    audioDone = true
                    Log.storage.info("Meeting sync skipped audio over the size limit.")
                }
            }

            let audioChanged = snapshot.audioFiles != item.snapshot.audioFiles
            if item.isDirty || audioChanged {
                let saved = try await cloud.saveSession(
                    snapshot,
                    transcript: item.transcriptChanged ? item.transcript : nil
                )
                guard saved else {
                    report.failures += 1
                    continue
                }
                try local.markPushed(
                    sessionId: snapshot.id,
                    changeSeq: item.changeSeq,
                    transcriptHash: snapshot.transcriptHash,
                    audioFiles: snapshot.audioFiles,
                    audioDone: audioDone
                )
                report.pushedSessions += 1
            } else if audioDone != nil {
                try local.markPushed(
                    sessionId: snapshot.id,
                    changeSeq: item.changeSeq,
                    transcriptHash: nil,
                    audioFiles: snapshot.audioFiles,
                    audioDone: audioDone
                )
            }
        }
    }

    /// `existing` with `added` replacing same-named files.
    nonisolated static func merged(_ existing: [MeetingAudioFileInfo], _ added: [MeetingAudioFileInfo]) -> [MeetingAudioFileInfo] {
        var result = existing.filter { file in !added.contains(where: { $0.fileName == file.fileName }) }
        result.append(contentsOf: added)
        return result.sorted { $0.fileName < $1.fileName }
    }

    // MARK: - Audio on demand

    /// Downloads a session's audio from iCloud into its folder under
    /// `audioRoot` and points the session at it. Returns the folder path.
    func downloadAudio(sessionId: String, audioRoot: URL) async throws -> String {
        let files = try local.remoteAudioFiles(sessionId: sessionId)
        guard !files.isEmpty else { throw MeetingSyncEngineError.noRemoteAudio }
        let directory = SessionAudioStorage.directory(forSessionId: sessionId, root: audioRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files where MeetingAudioSyncPolicy.isAllowed(fileName: file.fileName) {
            try await cloud.downloadAudio(
                sessionId: sessionId,
                fileName: file.fileName,
                to: directory.appendingPathComponent(file.fileName)
            )
        }
        try local.setAudioDirectory(directory.path, sessionId: sessionId)
        return directory.path
    }
}
