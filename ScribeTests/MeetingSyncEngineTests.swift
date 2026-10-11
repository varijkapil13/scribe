import GRDB
import XCTest
@testable import Scribe

// MARK: - Fake CloudKit

/// In-memory stand-in for the `Meetings` zone: latest version of each
/// record plus a change counter that serves as the change token.
actor FakeMeetingCloud: MeetingCloudServicing {

    private var seq = 0
    private var sessionRecords: [String: (snapshot: MeetingSessionSnapshot, seq: Int)] = [:]
    private var transcriptRecords: [String: (payload: MeetingTranscriptPayload, seq: Int)] = [:]
    private var audioRecords: [String: Data] = [:]

    private(set) var sessionSaves = 0
    private(set) var transcriptUploads = 0
    private(set) var audioUploads = 0
    private(set) var payloadDeletions: [String] = []
    private(set) var fetchCalls = 0

    func ensureZone() async throws {}

    func fetchChanges(since token: Data?) async throws -> MeetingCloudChangeBatch {
        fetchCalls += 1
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let sessions = sessionRecords.values.filter { $0.seq > since }.map { $0.snapshot }
        var transcripts: [String: MeetingTranscriptPayload] = [:]
        for (id, record) in transcriptRecords where record.seq > since {
            transcripts[id] = record.payload
        }
        return MeetingCloudChangeBatch(
            sessions: sessions,
            transcripts: transcripts,
            removedSessionIds: [],
            token: Data(String(seq).utf8),
            moreComing: false
        )
    }

    func fetchTranscript(sessionId: String) async throws -> MeetingTranscriptPayload? {
        transcriptRecords[sessionId]?.payload
    }

    func saveSession(_ snapshot: MeetingSessionSnapshot, transcript: MeetingTranscriptPayload?) async throws -> Bool {
        seq += 1
        sessionRecords[snapshot.id] = (snapshot, seq)
        sessionSaves += 1
        if let transcript {
            transcriptRecords[snapshot.id] = (transcript, seq)
            transcriptUploads += 1
        }
        return true
    }

    func uploadAudio(sessionId: String, files: [MeetingAudioUpload]) async throws -> [MeetingAudioFileInfo] {
        var uploaded: [MeetingAudioFileInfo] = []
        for file in files {
            guard let data = try? Data(contentsOf: file.fileURL) else { continue }
            audioRecords["\(sessionId)/\(file.info.fileName)"] = data
            uploaded.append(file.info)
            audioUploads += 1
        }
        return uploaded
    }

    func deleteSessionPayloads(sessionId: String) async throws {
        transcriptRecords[sessionId] = nil
        for key in audioRecords.keys where key.hasPrefix("\(sessionId)/") {
            audioRecords[key] = nil
        }
        payloadDeletions.append(sessionId)
    }

    func downloadAudio(sessionId: String, fileName: String, to destination: URL) async throws {
        guard let data = audioRecords["\(sessionId)/\(fileName)"] else { throw MeetingCloudServiceError.recordMissing }
        try data.write(to: destination)
    }

    // MARK: Test helpers

    func snapshot(_ id: String) -> MeetingSessionSnapshot? { sessionRecords[id]?.snapshot }
    func transcript(_ id: String) -> MeetingTranscriptPayload? { transcriptRecords[id]?.payload }
    func hasAudio(_ id: String, _ fileName: String) -> Bool { audioRecords["\(id)/\(fileName)"] != nil }

    /// Stores a version as if another device had pushed it.
    func inject(_ snapshot: MeetingSessionSnapshot, transcript: MeetingTranscriptPayload?) {
        seq += 1
        sessionRecords[snapshot.id] = (snapshot, seq)
        if let transcript { transcriptRecords[snapshot.id] = (transcript, seq) }
    }
}

// MARK: - Simulated device

/// One device: its own in-memory database and engine, sharing a fake zone.
private struct SimulatedDevice {
    let kind: MeetingDeviceKind
    let dbManager: DatabaseManager
    let local: MeetingSyncLocalStore
    let transcripts: TranscriptStore
    let bookmarks: SessionBookmarkStore
    let engine: MeetingSyncEngine

    init(kind: MeetingDeviceKind, cloud: FakeMeetingCloud) throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = MeetingSyncLocalStore(dbManager: manager)
        self.kind = kind
        self.dbManager = manager
        self.local = store
        self.transcripts = TranscriptStore(databaseManager: manager)
        self.bookmarks = SessionBookmarkStore(databaseManager: manager)
        self.engine = MeetingSyncEngine(local: store, cloud: cloud)
    }

    func options(syncAudio: Bool = false) -> MeetingSyncRoundOptions {
        MeetingSyncRoundOptions(
            deviceKind: kind,
            syncAudio: syncAudio,
            maxAudioFileBytes: MeetingAudioSyncPolicy.maxFileBytes,
            maxAudioSessionBytes: MeetingAudioSyncPolicy.maxSessionBytes,
            now: Date()
        )
    }

    @discardableResult
    func sync(syncAudio: Bool = false) async throws -> MeetingSyncRoundReport {
        try await engine.runRound(options(syncAudio: syncAudio))
    }

    /// A finished recording with three segments.
    @discardableResult
    func recordMeeting(title: String = "Weekly sync", finish: Bool = true) throws -> Session {
        let session = try transcripts.createSession(title: title, noteId: "note-\(title)")
        try transcripts.addSegment(sessionId: session.id, startMs: 0, endMs: 1_000, speaker: "you", text: "Morning everyone.")
        try transcripts.addSegment(sessionId: session.id, startMs: 1_200, endMs: 3_000, speaker: "remote", text: "Let's review the launch plan.")
        try transcripts.addSegment(sessionId: session.id, startMs: 3_100, endMs: 4_000, speaker: "remote", text: "Ship on Friday.")
        if finish { try transcripts.endSession(id: session.id) }
        return session
    }

    func segmentCount(_ sessionId: String) throws -> Int {
        try dbManager.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments WHERE sessionId = ?", arguments: [sessionId]) ?? 0
        }
    }

    /// Tests set the LWW clocks explicitly instead of relying on how much
    /// wall time passes between two in-memory writes.
    func setTombstoneClock(_ sessionId: String, _ date: Date) throws {
        try dbManager.database.write { db in
            try db.execute(sql: "UPDATE meeting_sync_tombstones SET deletedAt = ? WHERE sessionId = ?", arguments: [date, sessionId])
        }
    }

    func setSyncClock(_ sessionId: String, _ date: Date) throws {
        try dbManager.database.write { db in
            try db.execute(sql: "UPDATE meeting_sync_state SET updatedAt = ? WHERE sessionId = ?", arguments: [date, sessionId])
        }
    }
}

// MARK: - Local store + triggers

final class MeetingSyncLocalStoreTests: XCTestCase {

    func testMigrationIsRegistered() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let applied = try manager.database.read { db in
            try DatabaseManager.makeMigrator().appliedMigrations(db)
        }
        XCTAssertTrue(applied.contains("v28_meeting_sync"))
    }

    func testRecordingInProgressIsNotPendingUntilItEnds() throws {
        let device = try SimulatedDevice(kind: .mac, cloud: FakeMeetingCloud())
        let session = try device.recordMeeting(finish: false)
        XCTAssertFalse(try device.local.hasPendingWork())
        XCTAssertTrue(try device.local.pendingPushes(includeAudioBackfill: true, localDevice: .mac, localDeviceId: "d").isEmpty)
        XCTAssertNil(try device.local.pendingPush(sessionId: session.id, localDevice: .mac, localDeviceId: "d"))

        try device.transcripts.endSession(id: session.id)
        XCTAssertTrue(try device.local.hasPendingWork())
        let pending = try device.local.pendingPushes(includeAudioBackfill: false, localDevice: .mac, localDeviceId: "d")
        XCTAssertEqual(pending.map(\.snapshot.id), [session.id])
        XCTAssertEqual(pending.first?.transcript.entries.count, 3)
        XCTAssertEqual(pending.first?.snapshot.originDevice, .mac)
        XCTAssertEqual(pending.first?.snapshot.originDeviceId, "d")
    }

    func testPushBookkeepingAndRedirtyOnRename() throws {
        let device = try SimulatedDevice(kind: .mac, cloud: FakeMeetingCloud())
        let session = try device.recordMeeting()
        let push = try XCTUnwrap(device.local.pendingPush(sessionId: session.id, localDevice: .mac, localDeviceId: "d"))
        try device.local.markPushed(
            sessionId: session.id,
            changeSeq: push.changeSeq,
            transcriptHash: push.snapshot.transcriptHash,
            audioFiles: [],
            audioDone: nil
        )
        XCTAssertFalse(try device.local.hasPendingWork())

        // A per-device audio path change is not a syncable edit.
        try device.local.setAudioDirectory("/tmp/elsewhere", sessionId: session.id)
        XCTAssertFalse(try device.local.hasPendingWork())
        // Writing a value that didn't change doesn't count either.
        try device.transcripts.bindSession(session.id, toNote: "note-Weekly sync")
        XCTAssertFalse(try device.local.hasPendingWork())

        try device.transcripts.setSpeakerName("Priya", forKey: "remote", sessionId: session.id)
        XCTAssertTrue(try device.local.hasPendingWork())
        let again = try XCTUnwrap(device.local.pendingPush(sessionId: session.id, localDevice: .mac, localDeviceId: "d"))
        XCTAssertFalse(again.transcriptChanged, "a rename doesn't change the transcript payload")
        XCTAssertEqual(again.snapshot.speakerNames, ["remote": "Priya"])
    }

    func testDeletingASyncedSessionLeavesATombstoneButANeverSyncedOneDoesNot() throws {
        let device = try SimulatedDevice(kind: .mac, cloud: FakeMeetingCloud())
        let local = try device.recordMeeting(title: "Never synced")
        try device.transcripts.deleteSession(id: local.id)
        XCTAssertTrue(try device.local.pendingTombstones().isEmpty)

        let synced = try device.recordMeeting(title: "Synced")
        let push = try XCTUnwrap(device.local.pendingPush(sessionId: synced.id, localDevice: .mac, localDeviceId: "d"))
        try device.local.markPushed(sessionId: synced.id, changeSeq: push.changeSeq, transcriptHash: nil, audioFiles: [], audioDone: nil)
        try device.transcripts.deleteSession(id: synced.id)
        XCTAssertEqual(try device.local.pendingTombstones().map(\.sessionId), [synced.id])
        XCTAssertTrue(try device.local.hasPendingWork())
        XCTAssertEqual(try device.local.localState(sessionId: synced.id)?.side.isDeleted, true)
    }

    func testImportingTheSameVersionTwiceDoesNotDuplicateAnything() throws {
        let device = try SimulatedDevice(kind: .mac, cloud: FakeMeetingCloud())
        let transcript = MeetingTranscriptPayload(sessionId: "remote-1", entries: [
            .init(ordinal: 0, startMs: 0, endMs: 900, speaker: "you", text: "Hi", speakerOverride: nil),
            .init(ordinal: 1, startMs: 1_000, endMs: 1_900, speaker: "remote", text: "Hello", speakerOverride: "speaker-2")
        ])
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: "remote-1",
            summary: "We said hello.",
            keyDecisions: ["Say hi"],
            actionItems: [],
            keyTopics: ["Greetings"],
            followUpQuestions: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = MeetingSessionSnapshot(
            id: "remote-1",
            title: "Standup",
            noteId: "note-9",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            durationSeconds: 600,
            language: "en-US",
            summaryJSON: MeetingSyncJSON.encode(summary),
            speakerNames: ["speaker-2": "Priya"],
            bookmarks: [MeetingSyncBookmark(offsetMs: 500, label: "Decision", createdAt: Date(timeIntervalSince1970: 1_700_000_100))],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_700),
            originDevice: .iPhone,
            originDeviceId: "phone-1",
            transcriptHash: MeetingTranscriptCodec.hash(transcript),
            segmentCount: 2
        )

        try device.local.importRemote(snapshot, transcript: transcript, localDeviceId: "mac-1")
        try device.local.importRemote(snapshot, transcript: transcript, localDeviceId: "mac-1")

        XCTAssertEqual(try device.segmentCount("remote-1"), 2)
        XCTAssertEqual(try device.bookmarks.fetch(sessionId: "remote-1").count, 1)
        XCTAssertEqual(try device.transcripts.fetchSpeakerNames(sessionId: "remote-1"), ["speaker-2": "Priya"])
        XCTAssertEqual(try device.transcripts.fetchSummary(sessionId: "remote-1")?.summary, "We said hello.")
        let session = try XCTUnwrap(device.transcripts.fetchSession(id: "remote-1"))
        XCTAssertEqual(session.title, "Standup")
        XCTAssertEqual(session.noteId, "note-9")
        XCTAssertEqual(session.language, "en-US")
        let segments = try device.transcripts.fetchSegments(sessionId: "remote-1")
        XCTAssertEqual(segments.map(\.text), ["Hi", "Hello"])
        XCTAssertEqual(segments.last?.speakerOverride, "speaker-2")

        // An import is the remote version, not a local edit: nothing to push back.
        XCTAssertFalse(try device.local.hasPendingWork())
        XCTAssertEqual(try device.local.originDevice(sessionId: "remote-1"), .iPhone)
        XCTAssertEqual(try device.local.localState(sessionId: "remote-1")?.side.updatedAt, snapshot.updatedAt)

        // A changed transcript replaces the segments wholesale.
        var shorter = transcript
        shorter.entries = [transcript.entries[0]]
        try device.local.importRemote(snapshot, transcript: shorter, localDeviceId: "mac-1")
        XCTAssertEqual(try device.segmentCount("remote-1"), 1)
    }

    func testOwnRecordingComingBackHasNoOriginBadge() throws {
        let device = try SimulatedDevice(kind: .mac, cloud: FakeMeetingCloud())
        let snapshot = MeetingSessionSnapshot(
            id: "mine",
            title: "Mine",
            createdAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: Date(timeIntervalSince1970: 3_000),
            originDevice: .mac,
            originDeviceId: "this-mac"
        )
        try device.local.importRemote(snapshot, transcript: nil, localDeviceId: "this-mac")
        XCTAssertNil(try device.local.originDevice(sessionId: "mine"))
    }
}

// MARK: - Engine (two devices, one zone)

final class MeetingSyncEngineTests: XCTestCase {

    func testFinishedMeetingReachesTheOtherDeviceOnce() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)

        let session = try mac.recordMeeting()
        try mac.bookmarks.add(sessionId: session.id, offsetMs: 1_500, label: "Plan", createdAt: Date())
        let pushReport = try await mac.sync()
        XCTAssertEqual(pushReport.pushedSessions, 1)
        let uploads = await cloud.transcriptUploads
        XCTAssertEqual(uploads, 1)

        let pullReport = try await phone.sync()
        XCTAssertEqual(pullReport.importedSessionIds, [session.id])
        XCTAssertEqual(try phone.segmentCount(session.id), 3)
        XCTAssertEqual(try phone.bookmarks.fetch(sessionId: session.id).map(\.label), ["Plan"])
        XCTAssertEqual(try phone.local.originDevice(sessionId: session.id), .mac)
        XCTAssertNil(try mac.local.originDevice(sessionId: session.id))

        // Nothing new: no imports, no pushes, no echo.
        let quiet = try await phone.sync()
        XCTAssertTrue(quiet.importedSessionIds.isEmpty)
        XCTAssertEqual(quiet.pushedSessions, 0)
        let macQuiet = try await mac.sync()
        XCTAssertEqual(macQuiet.pushedSessions, 0)
        XCTAssertTrue(macQuiet.importedSessionIds.isEmpty)

        // Pulling everything again from scratch is idempotent.
        try phone.local.setChangeToken(nil)
        try await phone.sync()
        XCTAssertEqual(try phone.segmentCount(session.id), 3)
        XCTAssertEqual(try phone.bookmarks.fetch(sessionId: session.id).count, 1)
    }

    func testRecordingInProgressIsNeverPushed() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let session = try mac.recordMeeting(finish: false)

        let report = try await mac.sync()
        XCTAssertEqual(report.pushedSessions, 0)
        let remote = await cloud.snapshot(session.id)
        XCTAssertNil(remote)

        try mac.transcripts.endSession(id: session.id)
        try await mac.sync()
        let pushed = await cloud.snapshot(session.id)
        XCTAssertNotNil(pushed?.endedAt)
    }

    func testSpeakerRenameAndRelabelPropagate() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)
        let session = try mac.recordMeeting()
        try await mac.sync()
        try await phone.sync()

        // Rename on the phone: only the session record goes up.
        try phone.transcripts.setSpeakerName("Priya", forKey: "remote", sessionId: session.id)
        try phone.setSyncClock(session.id, Date(timeIntervalSinceNow: 60))
        let renameReport = try await phone.sync()
        XCTAssertEqual(renameReport.pushedSessions, 1)
        let uploadsAfterRename = await cloud.transcriptUploads
        XCTAssertEqual(uploadsAfterRename, 1, "a rename doesn't re-upload the transcript")
        let renamed = await cloud.snapshot(session.id)
        XCTAssertEqual(renamed?.originDevice, .mac, "the recording device stays the origin")

        try await mac.sync()
        XCTAssertEqual(try mac.transcripts.fetchSpeakerNames(sessionId: session.id), ["remote": "Priya"])
        XCTAssertNil(try mac.local.originDevice(sessionId: session.id))

        // Relabel a segment on the Mac (diarization / manual reassignment):
        // the transcript is re-uploaded and lands on the phone.
        let ids = try mac.transcripts.fetchSegments(sessionId: session.id).compactMap(\.id)
        try mac.transcripts.setSpeakerOverride("speaker-2", forSegmentIds: Array(ids.suffix(1)))
        try mac.setSyncClock(session.id, Date(timeIntervalSinceNow: 120))
        try await mac.sync()
        let uploadsAfterRelabel = await cloud.transcriptUploads
        XCTAssertEqual(uploadsAfterRelabel, 2)

        try await phone.sync()
        let phoneSegments = try phone.transcripts.fetchSegments(sessionId: session.id)
        XCTAssertEqual(phoneSegments.count, 3)
        XCTAssertEqual(phoneSegments.last?.speakerOverride, "speaker-2")
    }

    func testDeletionPropagatesAndDoesNotResurrect() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)
        let session = try mac.recordMeeting()
        try await mac.sync()
        try await phone.sync()
        XCTAssertNotNil(try phone.transcripts.fetchSession(id: session.id))

        try mac.transcripts.deleteSession(id: session.id)
        try mac.setTombstoneClock(session.id, Date(timeIntervalSinceNow: 60))
        let deleteReport = try await mac.sync()
        XCTAssertEqual(deleteReport.pushedDeletions, 1)
        let tombstone = await cloud.snapshot(session.id)
        XCTAssertEqual(tombstone?.isDeleted, true)
        let deletedPayloads = await cloud.payloadDeletions
        XCTAssertEqual(deletedPayloads, [session.id])

        let pullReport = try await phone.sync()
        XCTAssertEqual(pullReport.deletedSessionIds, [session.id])
        XCTAssertNil(try phone.transcripts.fetchSession(id: session.id))
        XCTAssertEqual(try phone.segmentCount(session.id), 0)

        // Applying the remote delete doesn't echo a second tombstone.
        let echo = try await phone.sync()
        XCTAssertEqual(echo.pushedDeletions, 0)

        // A stale (older) live version arriving later doesn't bring it back.
        var stale = try XCTUnwrap(tombstone)
        stale.isDeleted = false
        stale.title = "Stale"
        stale.updatedAt = stale.updatedAt.addingTimeInterval(-60)
        await cloud.inject(stale, transcript: nil)
        try await phone.sync()
        XCTAssertNil(try phone.transcripts.fetchSession(id: session.id))
    }

    func testLastWriterWinsOnTheSessionRecord() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)
        let session = try mac.recordMeeting(title: "Original")
        try await mac.sync()
        try await phone.sync()

        // Both rename; the phone's edit is newer.
        var macRow = try XCTUnwrap(mac.transcripts.fetchSession(id: session.id))
        macRow.title = "Mac title"
        try mac.transcripts.updateSession(macRow)
        try mac.setSyncClock(session.id, Date(timeIntervalSinceNow: -120))

        var phoneRow = try XCTUnwrap(phone.transcripts.fetchSession(id: session.id))
        phoneRow.title = "Phone title"
        try phone.transcripts.updateSession(phoneRow)
        try phone.setSyncClock(session.id, Date(timeIntervalSinceNow: -60))

        try await phone.sync()      // pushes the newer edit
        let macReport = try await mac.sync()  // pull: remote newer → overwrites the older local edit
        XCTAssertEqual(macReport.importedSessionIds, [session.id])
        XCTAssertEqual(macReport.pushedSessions, 0, "the losing local edit isn't pushed")
        XCTAssertEqual(try mac.transcripts.fetchSession(id: session.id)?.title, "Phone title")
        let remote = await cloud.snapshot(session.id)
        XCTAssertEqual(remote?.title, "Phone title")

        // An older remote version never overwrites a newer local one.
        var older = try XCTUnwrap(remote)
        older.title = "Ancient"
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        await cloud.inject(older, transcript: nil)
        try await mac.sync()
        XCTAssertEqual(try mac.transcripts.fetchSession(id: session.id)?.title, "Phone title")
    }

    func testAudioUploadsWhenEnabledAndDownloadsOnDemand() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSyncAudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try mac.recordMeeting()
        let macAudio = root.appendingPathComponent("mac", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
        try FileManager.default.createDirectory(at: macAudio, withIntermediateDirectories: true)
        try Data("fake-aac".utf8).write(to: macAudio.appendingPathComponent("mic.m4a"))
        try mac.local.setAudioDirectory(macAudio.path, sessionId: session.id)

        // Audio sync off: transcript only.
        try await mac.sync(syncAudio: false)
        let noAudio = await cloud.hasAudio(session.id, "mic.m4a")
        XCTAssertFalse(noAudio)

        // Turning it on backfills the already-synced recording.
        let audioReport = try await mac.sync(syncAudio: true)
        XCTAssertEqual(audioReport.uploadedAudioFiles, 1)
        let hasAudio = await cloud.hasAudio(session.id, "mic.m4a")
        XCTAssertTrue(hasAudio)
        let advertised = await cloud.snapshot(session.id)
        XCTAssertEqual(advertised?.audioFiles.map(\.fileName), ["mic.m4a"])
        // Not uploaded again on the next round.
        let again = try await mac.sync(syncAudio: true)
        XCTAssertEqual(again.uploadedAudioFiles, 0)

        // The phone gets the transcript; audio only when asked.
        try await phone.sync()
        XCTAssertNil(try phone.transcripts.fetchSession(id: session.id)?.audioDirectory)
        XCTAssertEqual(try phone.local.remoteAudioFiles(sessionId: session.id).map(\.fileName), ["mic.m4a"])

        let phoneRoot = root.appendingPathComponent("phone", isDirectory: true)
        let path = try await phone.engine.downloadAudio(sessionId: session.id, audioRoot: phoneRoot)
        let downloaded = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("mic.m4a"))
        XCTAssertEqual(String(decoding: downloaded, as: UTF8.self), "fake-aac")
        XCTAssertEqual(try phone.transcripts.fetchSession(id: session.id)?.audioDirectory, path)
        XCTAssertFalse(try phone.local.hasPendingWork(), "a downloaded audio path isn't a syncable edit")
    }

    func testAudioBackfillReachesADeviceThatAlreadyHasTheMeeting() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSyncAudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try mac.recordMeeting()
        let macAudio = root.appendingPathComponent(session.id, isDirectory: true)
        try FileManager.default.createDirectory(at: macAudio, withIntermediateDirectories: true)
        try Data("fake-aac".utf8).write(to: macAudio.appendingPathComponent("mic.m4a"))
        try mac.local.setAudioDirectory(macAudio.path, sessionId: session.id)

        // The phone imports the meeting before any audio is in iCloud.
        try await mac.sync(syncAudio: false)
        try await phone.sync()
        XCTAssertTrue(try phone.local.remoteAudioFiles(sessionId: session.id).isEmpty)

        // The backfill re-saves the record with its old clock (a tie on the
        // phone), but the phone still learns the audio is there.
        try await mac.sync(syncAudio: true)
        let report = try await phone.sync()
        XCTAssertTrue(report.importedSessionIds.isEmpty)
        XCTAssertEqual(report.audioAvailableSessionIds, [session.id])
        XCTAssertEqual(try phone.local.remoteAudioFiles(sessionId: session.id).map(\.fileName), ["mic.m4a"])
        XCTAssertFalse(try phone.local.hasPendingWork())

        // A later phone edit pushed with the list keeps it; a version
        // without the list never hides audio already known.
        var row = try XCTUnwrap(phone.transcripts.fetchSession(id: session.id))
        row.title = "Renamed on the phone"
        try phone.transcripts.updateSession(row)
        try await phone.sync()
        let pushed = await cloud.snapshot(session.id)
        XCTAssertEqual(pushed?.audioFiles.map(\.fileName), ["mic.m4a"])

        var stripped = try XCTUnwrap(pushed)
        stripped.audioFiles = []
        stripped.updatedAt = stripped.updatedAt.addingTimeInterval(60)
        await cloud.inject(stripped, transcript: nil)
        try await mac.sync()
        XCTAssertEqual(try mac.local.remoteAudioFiles(sessionId: session.id).map(\.fileName), ["mic.m4a"])
    }

    func testEditRightAfterImportBeatsItsBaseEvenWithASlowClock() async throws {
        let cloud = FakeMeetingCloud()
        let mac = try SimulatedDevice(kind: .mac, cloud: cloud)
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)
        let session = try mac.recordMeeting()
        // The Mac's clock runs an hour ahead of the phone's.
        try mac.setSyncClock(session.id, Date(timeIntervalSinceNow: 3_600))
        try await mac.sync()
        try await phone.sync()

        try phone.transcripts.setSpeakerName("Priya", forKey: "remote", sessionId: session.id)
        try await phone.sync()
        let base = try XCTUnwrap(mac.local.localState(sessionId: session.id)).side.updatedAt
        let remote = await cloud.snapshot(session.id)
        let pushed = try XCTUnwrap(remote)
        XCTAssertGreaterThan(pushed.updatedAt.timeIntervalSince(base), MeetingSyncMergePolicy.clockTolerance)

        let report = try await mac.sync()
        XCTAssertEqual(report.importedSessionIds, [session.id])
        XCTAssertEqual(try mac.transcripts.fetchSpeakerNames(sessionId: session.id), ["remote": "Priya"])
    }

    func testDownloadWithoutRemoteAudioFails() async throws {
        let cloud = FakeMeetingCloud()
        let phone = try SimulatedDevice(kind: .iPhone, cloud: cloud)
        do {
            _ = try await phone.engine.downloadAudio(sessionId: "none", audioRoot: FileManager.default.temporaryDirectory)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MeetingSyncEngineError, .noRemoteAudio)
        }
    }
}
