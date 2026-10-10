import CloudKit
import XCTest
@testable import Scribe

/// v20 planning fields on the CloudKit wire format: they round-trip, and a
/// record written by an older client (no planning keys) decodes with
/// defaults instead of failing.
final class TaskCloudRecordPlanningTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "Tasks", ownerName: CKCurrentUserDefaultName)

    func testPlanningFieldsRoundTrip() {
        let task = TodoTask(
            id: "task-p",
            title: "Plan the offsite",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            recurrenceRule: "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;X-SCRIBE-FROM=COMPLETION",
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_650_000_000),
            startAt: Date(timeIntervalSince1970: 1_699_000_000),
            scheduleBucket: .evening,
            estimatedMinutes: 90,
            areaId: "area-1",
            headingId: "heading-2"
        )
        let record = TaskCloudRecord.makeRecord(from: task, in: zoneID)
        XCTAssertEqual(record["scheduleBucket"] as? String, "evening")
        XCTAssertEqual(TaskCloudRecord.task(from: record), task)
    }

    func testLegacyRecordWithoutPlanningKeysUsesDefaults() throws {
        // Shaped like a record pushed by a pre-v20 client.
        let record = CKRecord(
            recordType: TaskCloudRecord.recordType,
            recordID: CKRecord.ID(recordName: "legacy", zoneID: zoneID)
        )
        record["title"] = "Old task"
        record["createdAt"] = Date(timeIntervalSince1970: 10)
        record["updatedAt"] = Date(timeIntervalSince1970: 20)

        let task = try XCTUnwrap(TaskCloudRecord.task(from: record))
        XCTAssertNil(task.startAt)
        XCTAssertEqual(task.scheduleBucket, .anytime)
        XCTAssertNil(task.estimatedMinutes)
        XCTAssertNil(task.areaId)
        XCTAssertNil(task.headingId)
    }

    func testUnknownBucketValueFallsBackToAnytime() throws {
        let record = TaskCloudRecord.makeRecord(
            from: TodoTask(id: "x", title: "X",
                           createdAt: Date(timeIntervalSince1970: 1),
                           updatedAt: Date(timeIntervalSince1970: 2)),
            in: zoneID
        )
        record["scheduleBucket"] = "a-future-bucket"
        XCTAssertEqual(try XCTUnwrap(TaskCloudRecord.task(from: record)).scheduleBucket, .anytime)
    }
}
