// ScribeTests/SessionAudioTests.swift
import XCTest
import GRDB
@testable import Scribe

/// Retained session audio: retention policy, folder path resolution,
/// cleanup, and the `v19_session_audio` migration.
final class AudioRetentionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testForeverNeverExpires() {
        XCTAssertNil(AudioRetentionPolicy.forever.expirationCutoff(now: now))
        XCTAssertFalse(AudioRetentionPolicy.forever.isExpired(
            createdAt: now.addingTimeInterval(-10 * 365 * 86_400), now: now))
    }

    func testRetentionDays() {
        XCTAssertNil(AudioRetentionPolicy.forever.retentionDays)
        XCTAssertEqual(AudioRetentionPolicy.days7.retentionDays, 7)
        XCTAssertEqual(AudioRetentionPolicy.days30.retentionDays, 30)
        XCTAssertEqual(AudioRetentionPolicy.days90.retentionDays, 90)
    }

    func testCutoffIsNowMinusDays() {
        XCTAssertEqual(AudioRetentionPolicy.days7.expirationCutoff(now: now),
                       now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(AudioRetentionPolicy.days90.expirationCutoff(now: now),
                       now.addingTimeInterval(-90 * 86_400))
    }

    func testExpiryBoundary() {
        let policy = AudioRetentionPolicy.days30
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        XCTAssertTrue(policy.isExpired(createdAt: cutoff.addingTimeInterval(-1), now: now))
        XCTAssertFalse(policy.isExpired(createdAt: cutoff, now: now), "exactly at the cutoff is kept")
        XCTAssertFalse(policy.isExpired(createdAt: now, now: now))
    }

    func testCurrentReadsDefaultsAndFallsBack() throws {
        let suite = "AudioRetentionPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AudioRetentionPolicy.current(in: defaults), .forever)
        defaults.set("30", forKey: AudioRetentionPolicy.defaultsKey)
        XCTAssertEqual(AudioRetentionPolicy.current(in: defaults), .days30)
        defaults.set("bogus", forKey: AudioRetentionPolicy.defaultsKey)
        XCTAssertEqual(AudioRetentionPolicy.current(in: defaults), .forever)
    }
}

final class SessionAudioStorageTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioStorageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: Path resolution

    func testRootDefaultsToApplicationSupport() {
        let appSupport = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        let root = SessionAudioStorage.rootDirectory(storageLocation: nil, applicationSupport: appSupport)
        XCTAssertEqual(root.path, "/Users/me/Library/Application Support/Scribe/Audio")

        let blank = SessionAudioStorage.rootDirectory(storageLocation: "  ", applicationSupport: appSupport)
        XCTAssertEqual(blank.path, root.path, "a blank storage location means default")
    }

    func testRootUsesStorageLocationWhenSet() {
        let appSupport = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        let root = SessionAudioStorage.rootDirectory(storageLocation: "/Volumes/Data/Scribe",
                                                     applicationSupport: appSupport)
        XCTAssertEqual(root.path, "/Volumes/Data/Scribe/Audio")
    }

    func testSessionFolderAndFileNames() {
        let dir = SessionAudioStorage.directory(forSessionId: "ABC", root: tempRoot)
        XCTAssertEqual(dir.lastPathComponent, "ABC")
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertEqual(SessionAudioStorage.micFileURL(in: dir).lastPathComponent, "mic.m4a")
        XCTAssertEqual(SessionAudioStorage.systemFileURL(in: dir).lastPathComponent, "system.m4a")
    }

    func testAudioDirectoryForNewSessionFollowsRetainToggle() throws {
        let suite = "SessionAudioStorageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(AppState.audioDirectoryForNewSession(sessionId: "S1", defaults: defaults))

        defaults.set(true, forKey: SessionAudioStorage.retainAudioKey)
        defaults.set("/tmp/scribe-audio-test", forKey: SessionAudioStorage.storageLocationKey)
        let dir = AppState.audioDirectoryForNewSession(sessionId: "S1", defaults: defaults)
        XCTAssertEqual(dir?.path, "/tmp/scribe-audio-test/Audio/S1")
    }

    // MARK: Cleanup

    func testRemoveDirectoryDeletesFolderAndToleratesMissing() throws {
        let dir = tempRoot.appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("mic.m4a"))

        SessionAudioStorage.removeDirectory(atPath: dir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        // Missing / nil paths are no-ops.
        SessionAudioStorage.removeDirectory(atPath: dir.path)
        SessionAudioStorage.removeDirectory(atPath: nil)
    }

    func testRemoveOrphanFoldersOnlyTouchesUnknownUUIDFolders() throws {
        let fm = FileManager.default
        let known = UUID().uuidString
        let orphan = UUID().uuidString
        for name in [known, orphan, "My Stuff"] {
            try fm.createDirectory(at: tempRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // A UUID-named *file* is not ours to delete either.
        let strayFile = UUID().uuidString
        try Data([0]).write(to: tempRoot.appendingPathComponent(strayFile))

        let removed = SessionAudioStorage.removeOrphanFolders(root: tempRoot, knownSessionIds: [known])

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(fm.fileExists(atPath: tempRoot.appendingPathComponent(known).path))
        XCTAssertFalse(fm.fileExists(atPath: tempRoot.appendingPathComponent(orphan).path))
        XCTAssertTrue(fm.fileExists(atPath: tempRoot.appendingPathComponent("My Stuff").path))
        XCTAssertTrue(fm.fileExists(atPath: tempRoot.appendingPathComponent(strayFile).path))
    }

    func testRemoveOrphanFoldersSkipsRecentlyTouched() throws {
        let orphan = UUID().uuidString
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(orphan),
                                                withIntermediateDirectories: true)
        let removed = SessionAudioStorage.removeOrphanFolders(
            root: tempRoot,
            knownSessionIds: [],
            untouchedSince: Date().addingTimeInterval(-3600)
        )
        XCTAssertEqual(removed, 0, "a folder created just now may belong to a recording in progress")
    }

    func testDiskUsageSumsFiles() throws {
        let dir = tempRoot.appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: dir.appendingPathComponent("mic.m4a"))
        try Data(count: 500).write(to: dir.appendingPathComponent("system.m4a"))

        XCTAssertGreaterThanOrEqual(SessionAudioStorage.diskUsage(of: tempRoot), 1500)
        XCTAssertEqual(SessionAudioStorage.diskUsage(of: tempRoot.appendingPathComponent("missing")), 0)
    }

    // MARK: Store integration

    func testDeleteSessionRemovesItsAudioFolder() throws {
        let db = try DatabaseManager(path: ":memory:")
        let store = TranscriptStore(databaseManager: db)
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("mic.m4a"))

        let session = try store.createSession(title: "T", noteId: "note", audioDirectory: dir.path)
        try store.deleteSession(id: session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testSweepExpiredAudioDeletesOnlyExpiredFinishedSessions() throws {
        let db = try DatabaseManager(path: ":memory:")
        let store = TranscriptStore(databaseManager: db)
        let now = Date()

        func makeSession(daysAgo: Double, ended: Bool) throws -> (Session, URL) {
            let id = UUID().uuidString
            let dir = tempRoot.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var session = try store.createSession(title: "S", noteId: "note", id: id, audioDirectory: dir.path)
            session.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
            session.endedAt = ended ? session.createdAt.addingTimeInterval(60) : nil
            try store.updateSession(session)
            return (session, dir)
        }

        let (old, oldDir) = try makeSession(daysAgo: 40, ended: true)
        let (recent, recentDir) = try makeSession(daysAgo: 2, ended: true)
        let (oldLive, oldLiveDir) = try makeSession(daysAgo: 40, ended: false)

        let removed = try store.sweepExpiredAudio(policy: .days30, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
        XCTAssertNil(try store.fetchSession(id: old.id)?.audioDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentDir.path))
        XCTAssertEqual(try store.fetchSession(id: recent.id)?.audioDirectory, recentDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldLiveDir.path), "never touch a session still recording")
        XCTAssertNotNil(try store.fetchSession(id: oldLive.id)?.audioDirectory)

        XCTAssertEqual(try store.sweepExpiredAudio(policy: .forever, now: now), 0)
    }
}

final class SessionAudioMigrationTests: XCTestCase {

    func testSessionsHasAudioDirectoryColumn() throws {
        let db = try DatabaseManager(path: ":memory:")
        let columns: [String] = try db.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(sessions)")
                .compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("audioDirectory"))
    }

    func testAudioDirectoryRoundTrips() throws {
        let db = try DatabaseManager(path: ":memory:")
        let store = TranscriptStore(databaseManager: db)

        let plain = try store.createSession(title: "No audio", noteId: "n1")
        XCTAssertNil(try store.fetchSession(id: plain.id)?.audioDirectory)

        let withAudio = try store.createSession(title: "Audio", noteId: "n1", audioDirectory: "/tmp/a/b")
        XCTAssertEqual(try store.fetchSession(id: withAudio.id)?.audioDirectory, "/tmp/a/b")

        try store.setAudioDirectory(nil, sessionId: withAudio.id)
        XCTAssertNil(try store.fetchSession(id: withAudio.id)?.audioDirectory)

        try store.setAudioDirectory("/tmp/c", sessionId: plain.id)
        XCTAssertEqual(try store.fetchSessionsWithAudio().map(\.id), [plain.id])
    }

    func testPreV19RowsReadAsNoAudio() throws {
        // Migrate to the step before v19, insert a legacy row, then run v19.
        let queue = try DatabaseQueue(path: ":memory:")
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v16_task_tombstones")
        let id = UUID().uuidString
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO sessions (id, title, createdAt, tags, noteId)
                VALUES (?, 'Legacy', ?, '[]', 'n1')
                """, arguments: [id, Date()])
        }
        try migrator.migrate(queue)

        let session = try queue.read { try Session.fetchOne($0, key: id) }
        XCTAssertNotNil(session)
        XCTAssertNil(session?.audioDirectory)
    }
}
