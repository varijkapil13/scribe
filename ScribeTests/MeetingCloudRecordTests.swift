import CloudKit
import XCTest
@testable import Scribe

/// Round-trips meeting snapshots through `CKRecord` in memory (no network or
/// container) so the wire mapping is pinned. The network layer
/// (`MeetingCloudKitService`) is validated on devices.
final class MeetingCloudRecordTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: MeetingCloudRecord.zoneName, ownerName: CKCurrentUserDefaultName)

    func testFullSessionRoundTrip() {
        let snapshot = MeetingSessionSnapshot(
            id: "session-1",
            title: "Design review",
            noteId: "note-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationSeconds: 3_600,
            language: "de-DE",
            tags: ["design", "q4"],
            calendarEventId: "event-1",
            calendarEventTitle: "Design review",
            attendees: [CalendarAttendee(name: "Priya", email: "priya@example.com")],
            summaryJSON: "{\"summary\":\"ok\"}",
            speakerNames: ["remote": "Priya", "you": "Me"],
            bookmarks: [MeetingSyncBookmark(offsetMs: 42_000, label: "Decision", createdAt: Date(timeIntervalSince1970: 1_700_000_042))],
            isDeleted: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_004_000),
            originDevice: .iPad,
            originDeviceId: "ipad-1",
            transcriptHash: "abc123",
            segmentCount: 128,
            audioFiles: [MeetingAudioFileInfo(fileName: "mic.m4a", byteCount: 1_234_567)]
        )

        let record = MeetingCloudRecord.makeSessionRecord(snapshot, in: zoneID)
        XCTAssertEqual(record.recordType, MeetingCloudRecord.sessionType)
        XCTAssertEqual(record.recordID.recordName, "session-1")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "Meetings")
        XCTAssertEqual(MeetingCloudRecord.snapshot(from: record), snapshot)
    }

    func testTombstoneRoundTrip() {
        let tombstone = MeetingSessionSnapshot.tombstone(id: "gone", deletedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let record = MeetingCloudRecord.makeSessionRecord(tombstone, in: zoneID)
        let restored = MeetingCloudRecord.snapshot(from: record)
        XCTAssertEqual(restored?.isDeleted, true)
        XCTAssertEqual(restored?.updatedAt, tombstone.updatedAt)
        XCTAssertEqual(restored, tombstone)
    }

    func testRejectsMalformedRecords() {
        let wrongType = CKRecord(recordType: "Task", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        XCTAssertNil(MeetingCloudRecord.snapshot(from: wrongType))

        let noClock = CKRecord(recordType: MeetingCloudRecord.sessionType, recordID: CKRecord.ID(recordName: "y", zoneID: zoneID))
        noClock[MeetingCloudRecord.Key.title] = "No updatedAt"
        XCTAssertNil(MeetingCloudRecord.snapshot(from: noClock))
    }

    func testTranscriptRecordCarriesTheCompressedPayload() throws {
        let payload = MeetingTranscriptPayload(sessionId: "session-1", entries: [
            .init(ordinal: 0, startMs: 0, endMs: 500, speaker: "you", text: "Hello", speakerOverride: nil)
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).smt")
        defer { try? FileManager.default.removeItem(at: url) }
        try MeetingTranscriptCodec.encode(payload).write(to: url)

        let record = MeetingCloudRecord.makeTranscriptRecord(
            sessionId: "session-1",
            payloadHash: MeetingTranscriptCodec.hash(payload),
            assetURL: url,
            in: zoneID
        )
        XCTAssertEqual(record.recordID.recordName, MeetingCloudRecord.transcriptRecordName(sessionId: "session-1"))
        XCTAssertEqual(MeetingCloudRecord.transcriptSessionId(of: record), "session-1")
        XCTAssertEqual(MeetingCloudRecord.transcript(from: record), payload)
    }

    func testPullsNeverRequestTheAudioAsset() {
        XCTAssertFalse(MeetingCloudRecord.desiredKeys.contains(MeetingCloudRecord.Key.audioAsset))
        XCTAssertTrue(MeetingCloudRecord.desiredKeys.contains(MeetingCloudRecord.Key.transcriptAsset))
        XCTAssertTrue(MeetingCloudRecord.desiredKeys.contains(MeetingCloudRecord.Key.updatedAt))
        XCTAssertEqual(Set(MeetingCloudRecord.desiredKeys).count, MeetingCloudRecord.desiredKeys.count)
    }

    func testRecordNamesAreDerivedFromTheSessionId() {
        XCTAssertEqual(MeetingCloudRecord.transcriptRecordName(sessionId: "abc"), "transcript.abc")
        XCTAssertEqual(MeetingCloudRecord.audioRecordName(sessionId: "abc", fileName: "mic.m4a"), "audio.abc.mic.m4a")
    }
}
