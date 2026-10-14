import Foundation
import GRDB

/// What the local database knows about one session, for merging.
struct MeetingLocalSyncState: Equatable, Sendable {
    var side: MeetingSyncMergePolicy.Side
    /// Hash of the transcript last pushed / imported.
    var transcriptHash: String?
    /// Local changes not yet pushed.
    var isDirty: Bool
}

/// A finished session ready to push.
struct MeetingPendingPush: Sendable {
    var snapshot: MeetingSessionSnapshot
    var transcript: MeetingTranscriptPayload
    /// The transcript differs from the one last pushed / imported, so it has
    /// to be (re)uploaded with this version.
    var transcriptChanged: Bool
    /// `changeSeq` the snapshot was read at; `markPushed` records it.
    var changeSeq: Int64
    /// Content changed since the last push (false = audio backfill only).
    var isDirty: Bool
    /// Recorded on this device (only those upload audio).
    var isLocalRecording: Bool
    var audioDirectory: String?
    var audioPushed: Bool
}

/// A session deleted on this device whose deletion hasn't been pushed.
struct MeetingPendingTombstone: Equatable, Sendable {
    var sessionId: String
    var deletedAt: Date
}

/// Local side of meeting sync: reads sessions into snapshots / transcript
/// payloads and writes remote versions back into the existing transcript
/// tables, plus the bookkeeping in `MeetingSyncSchema`'s tables.
///
/// Same threading model as `TranscriptStore` (GRDB's queue serializes
/// access), so it's a Sendable value the sync actor and the UI can share.
struct MeetingSyncLocalStore: Sendable {

    nonisolated static let shared = MeetingSyncLocalStore(dbManager: .shared)

    let dbManager: DatabaseManager

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    private var db: any DatabaseWriter { dbManager.database }

    private static let changeTokenKey = "changeToken"
    private static let deviceIdKey = "deviceId"

    // MARK: - Meta

    func changeToken() throws -> Data? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM meeting_sync_meta WHERE key = ?", arguments: [Self.changeTokenKey])
        }
    }

    func setChangeToken(_ token: Data?) throws {
        try db.write { db in
            if let token {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO meeting_sync_meta (key, value) VALUES (?, ?)",
                    arguments: [Self.changeTokenKey, token]
                )
            } else {
                try db.execute(sql: "DELETE FROM meeting_sync_meta WHERE key = ?", arguments: [Self.changeTokenKey])
            }
        }
    }

    /// This install's sync id (created on first use). Lets a device tell its
    /// own recordings apart when they come back from iCloud.
    func deviceId() throws -> String {
        try db.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM meeting_sync_meta WHERE key = ?", arguments: [Self.deviceIdKey]),
               let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
                return existing
            }
            let id = UUID().uuidString
            try db.execute(
                sql: "INSERT OR REPLACE INTO meeting_sync_meta (key, value) VALUES (?, ?)",
                arguments: [Self.deviceIdKey, Data(id.utf8)]
            )
            return id
        }
    }

    // MARK: - Local state

    func localState(sessionId: String) throws -> MeetingLocalSyncState? {
        try db.read { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT s.createdAt AS createdAt, s.endedAt AS endedAt,
                       st.updatedAt AS syncUpdatedAt, st.transcriptHash AS transcriptHash,
                       st.changeSeq AS changeSeq, st.pushedSeq AS pushedSeq
                FROM sessions s LEFT JOIN meeting_sync_state st ON st.sessionId = s.id
                WHERE s.id = ?
                """, arguments: [sessionId]) {
                let createdAt: Date = row["createdAt"]
                let endedAt: Date? = row["endedAt"]
                let syncUpdatedAt: Date? = row["syncUpdatedAt"]
                let changeSeq: Int64? = row["changeSeq"]
                let pushedSeq: Int64? = row["pushedSeq"]
                let transcriptHash: String? = row["transcriptHash"]
                return MeetingLocalSyncState(
                    side: .init(
                        updatedAt: syncUpdatedAt ?? endedAt ?? createdAt,
                        isDeleted: false,
                        isInProgress: endedAt == nil
                    ),
                    transcriptHash: transcriptHash,
                    isDirty: (changeSeq ?? 1) > (pushedSeq ?? 0)
                )
            }
            if let deletedAt = try Date.fetchOne(
                db,
                sql: "SELECT deletedAt FROM meeting_sync_tombstones WHERE sessionId = ?",
                arguments: [sessionId]
            ) {
                return MeetingLocalSyncState(
                    side: .init(updatedAt: deletedAt, isDeleted: true),
                    transcriptHash: nil,
                    isDirty: false
                )
            }
            return nil
        }
    }

    /// Whether a round has anything to push: a finished session with
    /// unpushed changes, or an unpushed deletion. Recordings in progress
    /// don't count (they're never synced until they finish).
    func hasPendingWork() throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM meeting_sync_state st JOIN sessions s ON s.id = st.sessionId
                    WHERE s.endedAt IS NOT NULL AND st.changeSeq > st.pushedSeq
                ) OR EXISTS (
                    SELECT 1 FROM meeting_sync_tombstones WHERE pushed = 0
                )
                """) ?? false
        }
    }

    /// The device that recorded `sessionId`, or nil when it was recorded here
    /// (or isn't known to sync).
    func originDevice(sessionId: String) throws -> MeetingDeviceKind? {
        try db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT originDevice FROM meeting_sync_state WHERE sessionId = ? AND originDeviceId IS NOT NULL",
                arguments: [sessionId]
            ).flatMap(MeetingDeviceKind.init(rawValue:))
        }
    }

    // MARK: - Push side

    func pendingTombstones() throws -> [MeetingPendingTombstone] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT sessionId, deletedAt FROM meeting_sync_tombstones WHERE pushed = 0 ORDER BY deletedAt")
                .map { MeetingPendingTombstone(sessionId: $0["sessionId"], deletedAt: $0["deletedAt"]) }
        }
    }

    func markTombstonePushed(sessionId: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meeting_sync_tombstones SET pushed = 1 WHERE sessionId = ?",
                arguments: [sessionId]
            )
        }
    }

    /// Finished sessions to push: those with unpushed changes, plus — when
    /// `includeAudioBackfill` — this device's recordings whose audio hasn't
    /// been uploaded yet. Sessions still recording are never included.
    func pendingPushes(
        includeAudioBackfill: Bool,
        localDevice: MeetingDeviceKind,
        localDeviceId: String
    ) throws -> [MeetingPendingPush] {
        let ids = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT st.sessionId FROM meeting_sync_state st JOIN sessions s ON s.id = st.sessionId
                WHERE s.endedAt IS NOT NULL
                  AND (st.changeSeq > st.pushedSeq
                       OR (? = 1 AND st.audioPushed = 0 AND st.originDeviceId IS NULL
                           AND s.audioDirectory IS NOT NULL))
                ORDER BY s.createdAt
                """, arguments: [includeAudioBackfill ? 1 : 0])
        }
        var pushes: [MeetingPendingPush] = []
        for id in ids {
            if let push = try pendingPush(sessionId: id, localDevice: localDevice, localDeviceId: localDeviceId) {
                pushes.append(push)
            }
        }
        return pushes
    }

    /// Reads one session as a push (nil when it vanished or is recording).
    func pendingPush(
        sessionId: String,
        localDevice: MeetingDeviceKind,
        localDeviceId: String
    ) throws -> MeetingPendingPush? {
        struct Read {
            var session: Session
            var segments: [Segment]
            var speakerNames: [String: String]
            var bookmarks: [MeetingSyncBookmark]
            var changeSeq: Int64
            var pushedSeq: Int64
            var storedHash: String?
            var originRaw: String?
            var originId: String?
            var audioPushed: Bool
            var remoteAudioJSON: String?
            var syncUpdatedAt: Date?
        }
        let read: Read? = try db.read { db in
            guard let session = try Session.fetchOne(db, key: sessionId),
                  MeetingSyncMergePolicy.isPushable(endedAt: session.endedAt) else { return nil }
            let segments = try Segment
                .filter(Column("sessionId") == sessionId)
                .order(Column("startMs"), Column("id"))
                .fetchAll(db)
            var result = Read(
                session: session,
                segments: segments,
                speakerNames: try Self.speakerNames(db, sessionId: sessionId),
                bookmarks: try Self.bookmarks(db, sessionId: sessionId),
                changeSeq: 1,
                pushedSeq: 0,
                storedHash: nil,
                originRaw: nil,
                originId: nil,
                audioPushed: false,
                remoteAudioJSON: nil,
                syncUpdatedAt: nil
            )
            if let state = try Row.fetchOne(
                db,
                sql: "SELECT * FROM meeting_sync_state WHERE sessionId = ?",
                arguments: [sessionId]
            ) {
                let changeSeq: Int64? = state["changeSeq"]
                let pushedSeq: Int64? = state["pushedSeq"]
                let storedHash: String? = state["transcriptHash"]
                let originRaw: String? = state["originDevice"]
                let originId: String? = state["originDeviceId"]
                let audioPushed: Int64? = state["audioPushed"]
                let remoteAudioJSON: String? = state["remoteAudio"]
                let syncUpdatedAt: Date? = state["updatedAt"]
                result.changeSeq = changeSeq ?? 1
                result.pushedSeq = pushedSeq ?? 0
                result.storedHash = storedHash
                result.originRaw = originRaw
                result.originId = originId
                result.audioPushed = (audioPushed ?? 0) != 0
                result.remoteAudioJSON = remoteAudioJSON
                result.syncUpdatedAt = syncUpdatedAt
            }
            return result
        }
        guard let read else { return nil }
        // Outside the read above (GRDB queues aren't reentrant). A summary
        // written in between bumps changeSeq, so it goes up next round.
        let summary = try TranscriptStore(databaseManager: dbManager).fetchSummary(sessionId: sessionId)

        let session = read.session
        let changeSeq = read.changeSeq
        let pushedSeq = read.pushedSeq
        let storedHash = read.storedHash
        let originRaw = read.originRaw
        let originId = read.originId
        let remoteAudioJSON = read.remoteAudioJSON
        let syncUpdatedAt = read.syncUpdatedAt

        let transcript = MeetingTranscriptPayload.make(sessionId: sessionId, segments: read.segments)
        let hash = MeetingTranscriptCodec.hash(transcript)
        let isLocalRecording = originId == nil

        let snapshot = MeetingSessionSnapshot(
            id: session.id,
            title: session.title,
            noteId: session.noteId,
            createdAt: session.createdAt,
            endedAt: session.endedAt,
            durationSeconds: session.durationSeconds,
            language: session.language,
            tags: session.tags,
            calendarEventId: session.calendarEventId,
            calendarEventTitle: session.calendarEventTitle,
            attendees: session.attendees,
            summaryJSON: summary.flatMap { MeetingSyncJSON.encode($0) },
            speakerNames: read.speakerNames,
            bookmarks: read.bookmarks,
            isDeleted: false,
            updatedAt: syncUpdatedAt ?? session.endedAt ?? session.createdAt,
            originDevice: isLocalRecording ? localDevice : (originRaw.flatMap(MeetingDeviceKind.init(rawValue:))),
            originDeviceId: isLocalRecording ? localDeviceId : originId,
            transcriptHash: hash,
            segmentCount: transcript.entries.count,
            audioFiles: Self.allowedAudio(MeetingSyncJSON.decode([MeetingAudioFileInfo].self, from: remoteAudioJSON) ?? [])
        )
        return MeetingPendingPush(
            snapshot: snapshot,
            transcript: transcript,
            transcriptChanged: storedHash != hash,
            changeSeq: changeSeq,
            isDirty: changeSeq > pushedSeq,
            isLocalRecording: isLocalRecording,
            audioDirectory: session.audioDirectory,
            audioPushed: read.audioPushed
        )
    }

    /// Records a successful push. `audioDone` nil leaves the audio state
    /// alone (audio sync off).
    func markPushed(
        sessionId: String,
        changeSeq: Int64,
        transcriptHash: String?,
        audioFiles: [MeetingAudioFileInfo],
        audioDone: Bool?
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting_sync_state
                    SET pushedSeq = MAX(pushedSeq, ?),
                        transcriptHash = COALESCE(?, transcriptHash),
                        remoteAudio = ?
                    WHERE sessionId = ?
                    """,
                arguments: [changeSeq, transcriptHash, Self.audioJSON(audioFiles), sessionId]
            )
            if let audioDone {
                try db.execute(
                    sql: "UPDATE meeting_sync_state SET audioPushed = ? WHERE sessionId = ?",
                    arguments: [audioDone ? 1 : 0, sessionId]
                )
            }
        }
    }

    // MARK: - Pull side

    /// Writes a remote version into the local tables (creating the session
    /// when it's new here). Idempotent: applying the same version twice
    /// leaves the same rows — segments, speaker names and bookmarks are
    /// replaced as a set, and only when they differ.
    ///
    /// - Parameter transcript: the transcript to apply, or nil to keep the
    ///   local segments (metadata-only change, or the transcript record
    ///   couldn't be fetched).
    func importRemote(
        _ snapshot: MeetingSessionSnapshot,
        transcript: MeetingTranscriptPayload?,
        localDeviceId: String
    ) throws {
        let sessionId = snapshot.id
        let usableTranscript = transcript.flatMap { $0.sessionId == sessionId ? $0 : nil }
        let summary = MeetingSyncJSON.decode(MeetingSummary.self, from: snapshot.summaryJSON)
            .flatMap { $0.sessionId == sessionId ? $0 : nil }

        try db.write { db in
            let existing = try Session.fetchOne(db, key: sessionId)
            let session = Session(
                id: sessionId,
                title: snapshot.title,
                createdAt: snapshot.createdAt,
                endedAt: snapshot.endedAt,
                durationSeconds: snapshot.durationSeconds,
                language: snapshot.language,
                tags: snapshot.tags,
                noteId: snapshot.noteId,
                calendarEventId: snapshot.calendarEventId,
                calendarEventTitle: snapshot.calendarEventTitle,
                attendees: snapshot.attendees,
                // Audio paths are per device: keep ours (downloaded audio).
                audioDirectory: existing?.audioDirectory
            )
            if let existing {
                if existing != session { try session.update(db) }
            } else {
                try session.insert(db)
            }

            if let usableTranscript {
                let current = try Segment
                    .filter(Column("sessionId") == sessionId)
                    .order(Column("startMs"), Column("id"))
                    .fetchAll(db)
                let currentHash = MeetingTranscriptCodec.hash(.make(sessionId: sessionId, segments: current))
                if currentHash != MeetingTranscriptCodec.hash(usableTranscript) {
                    try db.execute(sql: "DELETE FROM segments WHERE sessionId = ?", arguments: [sessionId])
                    for segment in usableTranscript.segments(forSessionId: sessionId) {
                        try segment.insert(db)
                    }
                }
            }

            if try Self.speakerNames(db, sessionId: sessionId) != snapshot.speakerNames {
                try db.execute(sql: "DELETE FROM session_speakers WHERE sessionId = ?", arguments: [sessionId])
                for (key, name) in snapshot.speakerNames.sorted(by: { $0.key < $1.key }) {
                    let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty, !trimmedName.isEmpty else { continue }
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO session_speakers (sessionId, speakerKey, displayName) VALUES (?, ?, ?)",
                        arguments: [sessionId, trimmedKey, trimmedName]
                    )
                }
            }

            let remoteBookmarks = Self.sortedBookmarks(snapshot.bookmarks)
            if try Self.bookmarks(db, sessionId: sessionId) != remoteBookmarks {
                try db.execute(sql: "DELETE FROM session_bookmarks WHERE sessionId = ?", arguments: [sessionId])
                for bookmark in remoteBookmarks {
                    var row = SessionBookmark(
                        sessionId: sessionId,
                        offsetMs: max(0, bookmark.offsetMs),
                        label: SessionBookmarkStore.normalizedLabel(bookmark.label),
                        createdAt: bookmark.createdAt
                    )
                    try row.insert(db)
                }
            }

            try db.execute(sql: "DELETE FROM meeting_sync_tombstones WHERE sessionId = ?", arguments: [sessionId])
        }

        // The summary goes through TranscriptStore (it also owns the action
        // items) in its own transaction, after the session row exists.
        let transcriptStore = TranscriptStore(databaseManager: dbManager)
        let currentSummary = try transcriptStore.fetchSummary(sessionId: sessionId)
        if let summary {
            if currentSummary != summary { try transcriptStore.saveSummary(summary) }
        } else if currentSummary != nil {
            try transcriptStore.deleteSummary(sessionId: sessionId)
        }

        // Settle: everything above is the remote version, not a local edit,
        // so it mustn't be pushed back. Clock = the remote clock.
        let isOwnRecording = snapshot.originDeviceId == localDeviceId
        let originDevice: String? = isOwnRecording ? nil : (snapshot.originDevice?.rawValue ?? MeetingDeviceKind.mac.rawValue)
        let originDeviceId: String? = isOwnRecording ? nil : (snapshot.originDeviceId ?? "unknown")
        let appliedHash = usableTranscript.map(MeetingTranscriptCodec.hash)
        try db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt) VALUES (?, ?)",
                arguments: [sessionId, snapshot.updatedAt]
            )
            // Audio in iCloud only ever grows (it goes away with the
            // session), so keep what we already knew about: a version saved
            // without the list (pushed by a device that hadn't seen it yet)
            // mustn't hide audio that is there.
            let knownAudio = try Self.storedRemoteAudio(db, sessionId: sessionId)
            try db.execute(
                sql: """
                    UPDATE meeting_sync_state
                    SET pushedSeq = changeSeq,
                        updatedAt = ?,
                        originDevice = ?,
                        originDeviceId = ?,
                        transcriptHash = COALESCE(?, transcriptHash),
                        remoteAudio = ?
                    WHERE sessionId = ?
                    """,
                arguments: [
                    snapshot.updatedAt,
                    originDevice,
                    originDeviceId,
                    appliedHash,
                    Self.audioJSON(Self.mergedAudio(knownAudio, snapshot.audioFiles)),
                    sessionId
                ]
            )
        }
    }

    /// Adds the audio files a remote version lists to the ones this device
    /// knows are in iCloud, without importing anything else. For versions
    /// that don't win last-writer-wins: an audio backfill ("Sync recording
    /// audio" turned on after the meeting synced) re-saves the record with
    /// its old clock, so devices that already hold that version see a tie.
    /// Returns whether anything changed. No-op for sessions not known here.
    @discardableResult
    func mergeRemoteAudio(sessionId: String, files: [MeetingAudioFileInfo]) throws -> Bool {
        let incoming = Self.allowedAudio(files)
        guard !incoming.isEmpty else { return false }
        return try db.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM meeting_sync_state WHERE sessionId = ?)",
                arguments: [sessionId]
            ) == true else { return false }
            let known = try Self.storedRemoteAudio(db, sessionId: sessionId)
            let merged = Self.mergedAudio(known, incoming)
            guard merged != known.sorted(by: { $0.fileName < $1.fileName }) else { return false }
            try db.execute(
                sql: "UPDATE meeting_sync_state SET remoteAudio = ? WHERE sessionId = ?",
                arguments: [Self.audioJSON(merged), sessionId]
            )
            return true
        }
    }

    /// Deletes the local session because a newer remote tombstone says so.
    /// The tombstone is kept (already pushed) so a stale copy can't come back.
    func applyRemoteDeletion(sessionId: String, deletedAt: Date) throws {
        let audioDirectory = try db.write { db -> String? in
            let path = try String.fetchOne(
                db,
                sql: "SELECT audioDirectory FROM sessions WHERE id = ?",
                arguments: [sessionId]
            )
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionId])
            try db.execute(
                sql: "INSERT OR REPLACE INTO meeting_sync_tombstones (sessionId, deletedAt, pushed) VALUES (?, ?, 1)",
                arguments: [sessionId, deletedAt]
            )
            return path
        }
        SessionAudioStorage.removeDirectory(atPath: audioDirectory)
    }

    /// Remembers a remote deletion of a session this device doesn't have.
    func rememberRemoteTombstone(sessionId: String, deletedAt: Date) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting_sync_tombstones (sessionId, deletedAt, pushed) VALUES (?, ?, 1)
                    ON CONFLICT(sessionId) DO UPDATE SET deletedAt = excluded.deletedAt
                    WHERE excluded.deletedAt > meeting_sync_tombstones.deletedAt
                    """,
                arguments: [sessionId, deletedAt]
            )
        }
    }

    /// Drops pushed tombstones older than `date` (housekeeping).
    func pruneTombstones(before date: Date) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_sync_tombstones WHERE pushed = 1 AND deletedAt < ?",
                arguments: [date]
            )
        }
    }

    // MARK: - Audio

    /// Audio files of `sessionId` available in iCloud.
    func remoteAudioFiles(sessionId: String) throws -> [MeetingAudioFileInfo] {
        let json = try db.read { db in
            try String.fetchOne(db, sql: "SELECT remoteAudio FROM meeting_sync_state WHERE sessionId = ?", arguments: [sessionId])
        }
        return Self.allowedAudio(MeetingSyncJSON.decode([MeetingAudioFileInfo].self, from: json) ?? [])
    }

    /// Points the session at downloaded audio. Not a syncable change (audio
    /// paths are per device), so it doesn't mark the session dirty.
    func setAudioDirectory(_ path: String?, sessionId: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET audioDirectory = ? WHERE id = ?", arguments: [path, sessionId])
        }
    }

    func audioDirectory(sessionId: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT audioDirectory FROM sessions WHERE id = ?", arguments: [sessionId])
        }
    }

    // MARK: - Helpers

    private static func speakerNames(_ db: Database, sessionId: String) throws -> [String: String] {
        var names: [String: String] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT speakerKey, displayName FROM session_speakers WHERE sessionId = ?",
            arguments: [sessionId]
        ) {
            let key: String = row["speakerKey"]
            let name: String = row["displayName"]
            names[key] = name
        }
        return names
    }

    private static func bookmarks(_ db: Database, sessionId: String) throws -> [MeetingSyncBookmark] {
        let rows = try SessionBookmark
            .filter(Column("sessionId") == sessionId)
            .fetchAll(db)
        return sortedBookmarks(rows.map {
            MeetingSyncBookmark(offsetMs: $0.offsetMs, label: $0.label, createdAt: $0.createdAt)
        })
    }

    /// Canonical bookmark order, so equal sets compare equal.
    nonisolated static func sortedBookmarks(_ bookmarks: [MeetingSyncBookmark]) -> [MeetingSyncBookmark] {
        bookmarks.sorted { lhs, rhs in
            if lhs.offsetMs != rhs.offsetMs { return lhs.offsetMs < rhs.offsetMs }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return (lhs.label ?? "") < (rhs.label ?? "")
        }
    }

    nonisolated static func allowedAudio(_ files: [MeetingAudioFileInfo]) -> [MeetingAudioFileInfo] {
        files.filter { MeetingAudioSyncPolicy.isAllowed(fileName: $0.fileName) && $0.byteCount > 0 }
    }

    private static func storedRemoteAudio(_ db: Database, sessionId: String) throws -> [MeetingAudioFileInfo] {
        let json = try String.fetchOne(
            db,
            sql: "SELECT remoteAudio FROM meeting_sync_state WHERE sessionId = ?",
            arguments: [sessionId]
        )
        return allowedAudio(MeetingSyncJSON.decode([MeetingAudioFileInfo].self, from: json) ?? [])
    }

    /// `known` plus `incoming` (incoming wins per file name), allowed names
    /// only, sorted by name.
    nonisolated static func mergedAudio(
        _ known: [MeetingAudioFileInfo],
        _ incoming: [MeetingAudioFileInfo]
    ) -> [MeetingAudioFileInfo] {
        let added = allowedAudio(incoming)
        var result = allowedAudio(known).filter { file in !added.contains(where: { $0.fileName == file.fileName }) }
        result.append(contentsOf: added)
        return result.sorted { $0.fileName < $1.fileName }
    }

    private static func audioJSON(_ files: [MeetingAudioFileInfo]) -> String? {
        files.isEmpty ? nil : MeetingSyncJSON.encode(files)
    }
}
