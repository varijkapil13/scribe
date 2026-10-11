import XCTest
@testable import Scribe

/// Pure pieces of CloudKit meeting sync: the transcript payload codec, the
/// last-writer-wins / tombstone policy, the audio upload limits and the
/// trigger timing rules.
final class MeetingTranscriptCodecTests: XCTestCase {

    private func payload(entries: Int, sessionId: String = "s-1") -> MeetingTranscriptPayload {
        let segments = (0..<entries).map { index in
            Segment(
                id: Int64(index + 1),
                sessionId: sessionId,
                startMs: index * 1_000,
                endMs: index * 1_000 + 900,
                speaker: index.isMultiple(of: 2) ? "you" : "remote",
                text: "We agreed to ship the quarterly roadmap review on Friday, item \(index).",
                speakerOverride: index == 3 ? "speaker-2" : nil
            )
        }
        return .make(sessionId: sessionId, segments: segments)
    }

    func testRoundTripPreservesEverything() throws {
        let original = payload(entries: 12)
        let data = try MeetingTranscriptCodec.encode(original)
        let decoded = try MeetingTranscriptCodec.decode(data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.entries.count, 12)
        XCTAssertEqual(decoded.entries[3].speakerOverride, "speaker-2")
        XCTAssertEqual(decoded.entries.map(\.ordinal), Array(0..<12))
    }

    func testEncodingIsCompressed() throws {
        let original = payload(entries: 200)
        let json = try MeetingTranscriptCodec.canonicalJSON(original)
        let encoded = try MeetingTranscriptCodec.encode(original)
        XCTAssertLessThan(encoded.count, json.count / 2, "repetitive transcript text should compress well")
        XCTAssertEqual(Array(encoded.prefix(4)), MeetingTranscriptCodec.magic)
    }

    func testRejectsDataThatIsNotATranscript() {
        XCTAssertThrowsError(try MeetingTranscriptCodec.decode(Data("hello".utf8))) { error in
            XCTAssertEqual(error as? MeetingTranscriptCodecError, .notATranscript)
        }
        XCTAssertThrowsError(try MeetingTranscriptCodec.decode(Data()))
    }

    func testRejectsNewerPayloadVersion() throws {
        var future = payload(entries: 1)
        future.version = MeetingTranscriptPayload.currentVersion + 1
        let data = try MeetingTranscriptCodec.encode(future)
        XCTAssertThrowsError(try MeetingTranscriptCodec.decode(data)) { error in
            XCTAssertEqual(error as? MeetingTranscriptCodecError, .unsupportedVersion(future.version))
        }
    }

    func testHashIsStableAndSensitiveToRelabels() {
        let a = payload(entries: 5)
        let b = payload(entries: 5)
        XCTAssertEqual(MeetingTranscriptCodec.hash(a), MeetingTranscriptCodec.hash(b))
        XCTAssertEqual(MeetingTranscriptCodec.hash(a).count, 64)

        var relabeled = a
        relabeled.entries[1].speakerOverride = "speaker-3"
        XCTAssertNotEqual(MeetingTranscriptCodec.hash(a), MeetingTranscriptCodec.hash(relabeled))
    }

    func testPayloadOrdersByStartThenInsertionAndIgnoresLocalIds() {
        let segments = [
            Segment(id: 30, sessionId: "s", startMs: 500, endMs: 900, speaker: "you", text: "second"),
            Segment(id: 10, sessionId: "s", startMs: 0, endMs: 400, speaker: "you", text: "first"),
            Segment(id: 40, sessionId: "s", startMs: 500, endMs: 950, speaker: "remote", text: "third")
        ]
        let payload = MeetingTranscriptPayload.make(sessionId: "s", segments: segments)
        XCTAssertEqual(payload.entries.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(payload.entries.map(\.ordinal), [0, 1, 2])

        // Same content with different local row ids hashes the same: ids
        // never cross devices.
        let renumbered = segments.map { segment -> Segment in
            var copy = segment
            copy.id = (segment.id ?? 0) + 1_000
            return copy
        }
        XCTAssertEqual(
            MeetingTranscriptCodec.hash(payload),
            MeetingTranscriptCodec.hash(.make(sessionId: "s", segments: renumbered))
        )

        let rebuilt = payload.segments(forSessionId: "s")
        XCTAssertEqual(rebuilt.map(\.text), ["first", "second", "third"])
        XCTAssertTrue(rebuilt.allSatisfy { $0.id == nil && $0.sessionId == "s" })
    }
}

final class MeetingSyncMergePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    private func side(_ date: Date, deleted: Bool = false, inProgress: Bool = false) -> MeetingSyncMergePolicy.Side {
        .init(updatedAt: date, isDeleted: deleted, isInProgress: inProgress)
    }

    func testUnknownLocally() {
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: nil, remote: side(t0)), .applyRemote)
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: nil, remote: side(t0, deleted: true)), .rememberTombstone)
    }

    func testLastWriterWins() {
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t0), remote: side(t1)), .applyRemote)
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t1), remote: side(t0)), .keepLocal)
        // Ties (and sub-millisecond differences from SQLite's precision) keep local.
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t1), remote: side(t1)), .keepLocal)
        XCTAssertEqual(
            MeetingSyncMergePolicy.resolve(local: side(t1), remote: side(t1.addingTimeInterval(0.0004))),
            .keepLocal
        )
    }

    func testTombstones() {
        // Newer remote delete removes the local copy.
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t0), remote: side(t1, deleted: true)), .applyRemoteDelete)
        // An older remote delete loses to a newer local edit.
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t1), remote: side(t0, deleted: true)), .keepLocal)
        // A local tombstone beats a stale remote edit (no resurrection)…
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t1, deleted: true), remote: side(t0)), .keepLocal)
        // …but a genuinely newer remote edit wins.
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t0, deleted: true), remote: side(t1)), .applyRemote)
        // Both deleted: nothing to do.
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t0, deleted: true), remote: side(t1, deleted: true)), .keepLocal)
    }

    func testRecordingInProgressIsNeverOverwritten() {
        XCTAssertEqual(MeetingSyncMergePolicy.resolve(local: side(t0, inProgress: true), remote: side(t1)), .keepLocal)
        XCTAssertEqual(
            MeetingSyncMergePolicy.resolve(local: side(t0, inProgress: true), remote: side(t1, deleted: true)),
            .keepLocal
        )
        XCTAssertFalse(MeetingSyncMergePolicy.isPushable(endedAt: nil))
        XCTAssertTrue(MeetingSyncMergePolicy.isPushable(endedAt: t0))
    }

    func testNeedsTranscript() {
        XCTAssertTrue(MeetingSyncMergePolicy.needsTranscript(remoteHash: "a", localHash: nil))
        XCTAssertTrue(MeetingSyncMergePolicy.needsTranscript(remoteHash: "a", localHash: "b"))
        XCTAssertFalse(MeetingSyncMergePolicy.needsTranscript(remoteHash: "a", localHash: "a"))
        XCTAssertFalse(MeetingSyncMergePolicy.needsTranscript(remoteHash: nil, localHash: "a"))
    }
}

final class MeetingAudioSyncPolicyTests: XCTestCase {

    func testSelectsAllowedFilesWithinLimits() {
        let candidates = [
            MeetingAudioFileInfo(fileName: "system.m4a", byteCount: 50),
            MeetingAudioFileInfo(fileName: "mic.m4a", byteCount: 40),
            MeetingAudioFileInfo(fileName: "../evil.m4a", byteCount: 1),
            MeetingAudioFileInfo(fileName: "timing.json", byteCount: 0)
        ]
        let picked = MeetingAudioSyncPolicy.selectUploads(candidates, maxFile: 100, maxTotal: 1_000)
        XCTAssertEqual(picked.map(\.fileName), ["mic.m4a", "system.m4a"])
    }

    func testSkipsFilesOverTheLimits() {
        let candidates = [
            MeetingAudioFileInfo(fileName: "mic.m4a", byteCount: 80),
            MeetingAudioFileInfo(fileName: "system.m4a", byteCount: 80),
            MeetingAudioFileInfo(fileName: "timing.json", byteCount: 5)
        ]
        // Per-file cap.
        XCTAssertEqual(MeetingAudioSyncPolicy.selectUploads(candidates, maxFile: 50, maxTotal: 1_000).map(\.fileName), ["timing.json"])
        // Per-session cap: the second large file doesn't fit, the small one does.
        XCTAssertEqual(
            MeetingAudioSyncPolicy.selectUploads(candidates, maxFile: 100, maxTotal: 100).map(\.fileName),
            ["mic.m4a", "timing.json"]
        )
    }

    func testOnlyKnownFileNamesAreAllowed() {
        XCTAssertTrue(MeetingAudioSyncPolicy.isAllowed(fileName: "mic.m4a"))
        XCTAssertFalse(MeetingAudioSyncPolicy.isAllowed(fileName: "/etc/passwd"))
        XCTAssertFalse(MeetingAudioSyncPolicy.isAllowed(fileName: "mic.m4a/../../x"))
    }

    func testMergedAudioReplacesSameNamedFiles() {
        let merged = MeetingSyncEngine.merged(
            [MeetingAudioFileInfo(fileName: "mic.m4a", byteCount: 1), MeetingAudioFileInfo(fileName: "system.m4a", byteCount: 2)],
            [MeetingAudioFileInfo(fileName: "mic.m4a", byteCount: 9)]
        )
        XCTAssertEqual(merged, [MeetingAudioFileInfo(fileName: "mic.m4a", byteCount: 9), MeetingAudioFileInfo(fileName: "system.m4a", byteCount: 2)])
    }
}

final class MeetingSyncTriggerPolicyTests: XCTestCase {

    func testThrottlesActivationAndPeriodicButNotLocalChanges() {
        var policy = MeetingSyncTriggerPolicy(throttleInterval: 300)
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(policy.shouldStart(.activation, now: start))
        policy.didStart(at: start)
        XCTAssertFalse(policy.shouldStart(.manual, now: start), "never overlaps a running round")
        policy.didFinish(at: start.addingTimeInterval(5))

        let soon = start.addingTimeInterval(60)
        XCTAssertFalse(policy.shouldStart(.activation, now: soon))
        XCTAssertFalse(policy.shouldStart(.periodic, now: soon))
        XCTAssertTrue(policy.shouldStart(.localChange, now: soon))
        XCTAssertTrue(policy.shouldStart(.manual, now: soon))
        XCTAssertTrue(policy.shouldStart(.enabled, now: soon))

        let later = start.addingTimeInterval(301)
        XCTAssertTrue(policy.shouldStart(.activation, now: later))
        XCTAssertTrue(policy.shouldStart(.periodic, now: later))
    }

    func testSettingsRequireTheICloudToggle() {
        let suite = "MeetingSyncSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MeetingSyncSettings.enabledKey)
        defaults.set(true, forKey: MeetingSyncSettings.audioEnabledKey)
        XCTAssertFalse(MeetingSyncSettings.isMeetingSyncOn(defaults), "sub-toggle alone isn't enough")
        XCTAssertFalse(MeetingSyncSettings.isAudioSyncOn(defaults))

        defaults.set(true, forKey: CloudKitSyncService.enabledDefaultsKey)
        XCTAssertTrue(MeetingSyncSettings.isMeetingSyncOn(defaults))
        XCTAssertTrue(MeetingSyncSettings.isAudioSyncOn(defaults))

        defaults.set(false, forKey: MeetingSyncSettings.enabledKey)
        XCTAssertFalse(MeetingSyncSettings.isAudioSyncOn(defaults), "audio needs meeting sync")
    }
}
