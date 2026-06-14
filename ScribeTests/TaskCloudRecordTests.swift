import CloudKit
import XCTest
@testable import Scribe

/// Round-trips `TodoTask` through `CKRecord` in memory (no network/container)
/// so the wire mapping — the bit most likely to silently drop a field — is
/// pinned. The CloudKit *network* layer in CloudKitSyncService is not testable
/// offline and is validated on-device.
final class TaskCloudRecordTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "Tasks", ownerName: CKCurrentUserDefaultName)

    func testFullyPopulatedRoundTrip() {
        let task = TodoTask(
            id: "task-1",
            title: "Ship the iOS app",
            notes: "with sync",
            projectId: "proj-9",
            priority: .high,
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            remindAt: Date(timeIntervalSince1970: 1_700_003_600),
            recurrenceRule: "FREQ=WEEKLY;BYDAY=MO",
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_650_000_000),
            sortOrder: 7,
            sourceSessionId: "sess-3",
            sourceActionItemId: "ai-4",
            cancelledAt: nil,
            isPinned: true
        )

        let record = TaskCloudRecord.makeRecord(from: task, in: zoneID)
        XCTAssertEqual(record.recordType, TaskCloudRecord.recordType)
        XCTAssertEqual(record.recordID.recordName, task.id)

        let restored = TaskCloudRecord.task(from: record)
        XCTAssertEqual(restored, task)
    }

    func testMinimalRoundTripPreservesNils() {
        let task = TodoTask(
            id: "task-2",
            title: "Bare task",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let record = TaskCloudRecord.makeRecord(from: task, in: zoneID)
        let restored = TaskCloudRecord.task(from: record)
        XCTAssertEqual(restored, task)
        XCTAssertNil(restored?.projectId)
        XCTAssertNil(restored?.priority)
        XCTAssertNil(restored?.dueAt)
        XCTAssertFalse(restored?.isPinned ?? true)
    }

    func testWrongRecordTypeReturnsNil() {
        let record = CKRecord(
            recordType: "NotATask",
            recordID: CKRecord.ID(recordName: "x", zoneID: zoneID)
        )
        XCTAssertNil(TaskCloudRecord.task(from: record))
    }

    func testMissingRequiredFieldReturnsNil() {
        // Right type but no title/timestamps → not a well-formed task.
        let record = CKRecord(
            recordType: TaskCloudRecord.recordType,
            recordID: CKRecord.ID(recordName: "y", zoneID: zoneID)
        )
        XCTAssertNil(TaskCloudRecord.task(from: record))
    }
}
