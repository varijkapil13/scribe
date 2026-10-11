import CloudKit
import XCTest
@testable import Scribe

/// Pins the CloudKit wire format for areas, projects, project headings and
/// task tags (pure CKRecord mapping, no container), plus the zone-change
/// decoder and push-batch encoder that sort records by kind.
final class TaxonomyCloudRecordTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "Tasks", ownerName: CKCurrentUserDefaultName)
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Round trips

    func testAreaRoundTrip() throws {
        let entry = TaxonomySyncEntry(item: TaskArea(id: "area-1", name: "Work", sortOrder: 3, symbol: "briefcase"),
                                      updatedAt: stamp)
        let record = TaxonomyCloudRecord.makeRecord(area: entry, in: zoneID)
        XCTAssertEqual(record.recordType, "Area")
        XCTAssertEqual(record.recordID.recordName, "taxonomy.area.area-1")
        XCTAssertEqual(TaxonomyCloudRecord.area(from: record), entry)
    }

    func testProjectRoundTrip() throws {
        let project = Project(id: "p-1", name: "Launch", color: "#FF8800", icon: "rocket",
                              createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                              sortOrder: 2, areaId: "area-1")
        let entry = TaxonomySyncEntry(item: project, updatedAt: stamp)
        let record = TaxonomyCloudRecord.makeRecord(project: entry, in: zoneID)
        XCTAssertEqual(record.recordType, "Project")
        XCTAssertEqual(TaxonomyCloudRecord.project(from: record), entry)
    }

    func testMinimalProjectRoundTripPreservesNils() throws {
        let project = Project(id: "p-2", name: "Bare", createdAt: stamp, sortOrder: 0)
        let entry = TaxonomySyncEntry(item: project, updatedAt: stamp)
        let restored = try XCTUnwrap(TaxonomyCloudRecord.project(
            from: TaxonomyCloudRecord.makeRecord(project: entry, in: zoneID)))
        XCTAssertEqual(restored, entry)
        XCTAssertNil(restored.item.color)
        XCTAssertNil(restored.item.icon)
        XCTAssertNil(restored.item.areaId)
    }

    func testHeadingRoundTrip() throws {
        let entry = TaxonomySyncEntry(item: ProjectHeading(id: "h-1", projectId: "p-1", title: "Phase 1", sortOrder: 4),
                                      updatedAt: stamp)
        let record = TaxonomyCloudRecord.makeRecord(heading: entry, in: zoneID)
        XCTAssertEqual(record.recordType, "ProjectHeading")
        XCTAssertEqual(TaxonomyCloudRecord.heading(from: record), entry)
    }

    // MARK: - Backward-compatible decoding

    func testDecodingDefaultsAbsentOptionalFields() throws {
        // A sparse record (e.g. from a future writer that dropped fields).
        let projectRecord = CKRecord(recordType: "Project",
                                     recordID: CKRecord.ID(recordName: "taxonomy.project.p-9", zoneID: zoneID))
        projectRecord["name"] = "Sparse"
        projectRecord["updatedAt"] = stamp
        let project = try XCTUnwrap(TaxonomyCloudRecord.project(from: projectRecord))
        XCTAssertEqual(project.item.id, "p-9")
        XCTAssertEqual(project.item.createdAt, stamp, "createdAt falls back to updatedAt")
        XCTAssertEqual(project.item.sortOrder, 0)
        XCTAssertNil(project.item.areaId)

        let headingRecord = CKRecord(recordType: "ProjectHeading",
                                     recordID: CKRecord.ID(recordName: "taxonomy.heading.h-9", zoneID: zoneID))
        headingRecord["projectId"] = "p-9"
        headingRecord["updatedAt"] = stamp
        let heading = try XCTUnwrap(TaxonomyCloudRecord.heading(from: headingRecord))
        XCTAssertEqual(heading.item.title, "")
        XCTAssertEqual(heading.item.sortOrder, 0)

        let areaRecord = CKRecord(recordType: "Area",
                                  recordID: CKRecord.ID(recordName: "taxonomy.area.a-9", zoneID: zoneID))
        areaRecord["name"] = "Home"
        areaRecord["updatedAt"] = stamp
        let area = try XCTUnwrap(TaxonomyCloudRecord.area(from: areaRecord))
        XCTAssertNil(area.item.symbol)
        XCTAssertEqual(area.item.sortOrder, 0)
    }

    func testMalformedRecordsDecodeToNil() {
        let noStamp = CKRecord(recordType: "Area", recordID: CKRecord.ID(recordName: "taxonomy.area.x", zoneID: zoneID))
        noStamp["name"] = "No timestamp"
        XCTAssertNil(TaxonomyCloudRecord.area(from: noStamp))

        let wrongType = CKRecord(recordType: "Task", recordID: CKRecord.ID(recordName: "taxonomy.project.x", zoneID: zoneID))
        wrongType["name"] = "Not a project"
        wrongType["updatedAt"] = stamp
        XCTAssertNil(TaxonomyCloudRecord.project(from: wrongType))

        let orphanHeading = CKRecord(recordType: "ProjectHeading",
                                     recordID: CKRecord.ID(recordName: "taxonomy.heading.x", zoneID: zoneID))
        orphanHeading["updatedAt"] = stamp
        XCTAssertNil(TaxonomyCloudRecord.heading(from: orphanHeading), "A heading needs its project id")
    }

    func testRecordNamesParseByKind() {
        XCTAssertEqual(TaxonomyCloudRecord.parse(recordName: "taxonomy.area.a1")?.kind, .area)
        XCTAssertEqual(TaxonomyCloudRecord.parse(recordName: "taxonomy.project.p1")?.id, "p1")
        XCTAssertEqual(TaxonomyCloudRecord.parse(recordName: "taxonomy.heading.h1")?.kind, .heading)
        XCTAssertNil(TaxonomyCloudRecord.parse(recordName: "6F9619FF-8B86-D011-B42D-00C04FC964FF"), "Task ids are bare")
        XCTAssertNil(TaxonomyCloudRecord.parse(recordName: "taxonomy.project."), "Empty id")
    }

    // MARK: - Task tags

    func testTaskTagsRoundTripNormalizedAndSorted() {
        let task = TodoTask(id: "t-1", title: "Tagged", createdAt: stamp, updatedAt: stamp)
        let record = TaskCloudRecord.makeRecord(from: task, in: zoneID)
        TaskCloudRecord.applyTags(["  Work ", "errand", "work", ""], to: record)
        XCTAssertEqual(TaskCloudRecord.tags(from: record), ["errand", "work"])
        XCTAssertEqual(TaskCloudRecord.task(from: record), task, "Tags don't disturb the task fields")
    }

    func testTaskRecordWithoutTagsIsUnknown() {
        // Written by a client that predates tag sync: no tags, no marker.
        let record = TaskCloudRecord.makeRecord(
            from: TodoTask(id: "t-2", title: "Old writer", createdAt: stamp, updatedAt: stamp), in: zoneID)
        XCTAssertNil(TaskCloudRecord.tags(from: record), "Absent tags mean 'keep local', never 'no tags'")
    }

    func testMarkedRecordWithoutTagListMeansNoTags() {
        // CloudKit may return an empty list as absent; the marker disambiguates.
        let record = TaskCloudRecord.makeRecord(
            from: TodoTask(id: "t-3", title: "Cleared", createdAt: stamp, updatedAt: stamp), in: zoneID)
        record[TaskCloudRecord.taxonomySchemaKey] = TaskCloudRecord.taxonomySchemaVersion
        XCTAssertEqual(TaskCloudRecord.tags(from: record), [])
    }

    func testLinksAreAuthoritativeOnlyForTheTaxonomyAwareWritersOwnVersion() {
        let task = TodoTask(id: "t-4", title: "Filed", createdAt: stamp, updatedAt: stamp, areaId: "a-1")
        let record = TaskCloudRecord.makeRecord(from: task, in: zoneID)
        XCTAssertFalse(TaskCloudRecord.linksAreAuthoritative(in: record), "No marker: an older writer")
        TaskCloudRecord.applyTags(["x"], to: record)
        XCTAssertTrue(TaskCloudRecord.linksAreAuthoritative(in: record))

        // An older client re-saves with `.changedKeys`: its task fields land,
        // the tag fields from the earlier save stay on the server.
        var edited = task
        edited.title = "Edited on an older client"
        edited.areaId = nil
        edited.updatedAt = stamp.addingTimeInterval(60)
        TaskCloudRecord.apply(edited, to: record)
        XCTAssertEqual(TaskCloudRecord.tags(from: record), ["x"], "Tags are still the last known ones")
        XCTAssertFalse(TaskCloudRecord.linksAreAuthoritative(in: record),
                       "The older writer's empty area can't speak for links it never knew")
        let decoded = TaskZoneChangeDecoder.decode(records: [record], deletedRecordNames: [],
                                                   token: nil, moreComing: false)
        XCTAssertEqual(decoded.taskTags, ["t-4": ["x"]])
        XCTAssertTrue(decoded.taskLinksAuthoritative.isEmpty)
    }

    // MARK: - Decoder / encoder

    func testDecoderSortsRecordsAndDeletionsByKind() {
        let task = TodoTask(id: "t-1", title: "Task", projectId: "p-1", createdAt: stamp, updatedAt: stamp)
        let tagged = TaskCloudRecord.makeRecord(from: task, in: zoneID)
        TaskCloudRecord.applyTags(["b", "a"], to: tagged)
        let legacy = TaskCloudRecord.makeRecord(
            from: TodoTask(id: "t-2", title: "Legacy", createdAt: stamp, updatedAt: stamp), in: zoneID)
        let records = [
            tagged, legacy,
            TaxonomyCloudRecord.makeRecord(area: .init(item: TaskArea(id: "a-1", name: "A"), updatedAt: stamp), in: zoneID),
            TaxonomyCloudRecord.makeRecord(project: .init(item: Project(id: "p-1", name: "P", createdAt: stamp), updatedAt: stamp), in: zoneID),
            TaxonomyCloudRecord.makeRecord(heading: .init(item: ProjectHeading(id: "h-1", projectId: "p-1", title: "H"), updatedAt: stamp), in: zoneID),
            CKRecord(recordType: "SomethingNew", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        ]
        let result = TaskZoneChangeDecoder.decode(
            records: records,
            deletedRecordNames: ["t-9", "taxonomy.area.a-9", "taxonomy.project.p-9", "taxonomy.heading.h-9"],
            token: nil, moreComing: true)

        XCTAssertEqual(Set(result.changed.map(\.id)), ["t-1", "t-2"])
        XCTAssertEqual(result.taskTags, ["t-1": ["a", "b"]], "Legacy task has no tag entry")
        XCTAssertEqual(result.areas.map(\.item.id), ["a-1"])
        XCTAssertEqual(result.projects.map(\.item.id), ["p-1"])
        XCTAssertEqual(result.headings.map(\.item.id), ["h-1"])
        XCTAssertEqual(result.deletedIDs, ["t-9"])
        XCTAssertEqual(result.deletedAreaIDs, ["a-9"])
        XCTAssertEqual(result.deletedProjectIDs, ["p-9"])
        XCTAssertEqual(result.deletedHeadingIDs, ["h-9"])
        XCTAssertTrue(result.moreComing)
    }

    func testPushBatchEncodesEveryKind() throws {
        var batch = TaskSyncPushBatch()
        batch.tasks = [TodoTask(id: "t-1", title: "Tagged", createdAt: stamp, updatedAt: stamp),
                       TodoTask(id: "t-2", title: "Untagged", createdAt: stamp, updatedAt: stamp)]
        batch.taskTags = ["t-1": ["x"], "t-2": []]
        batch.areas = [.init(item: TaskArea(id: "a-1", name: "A"), updatedAt: stamp)]
        batch.projects = [.init(item: Project(id: "p-1", name: "P", createdAt: stamp), updatedAt: stamp)]
        batch.headings = [.init(item: ProjectHeading(id: "h-1", projectId: "p-1", title: "H"), updatedAt: stamp)]
        batch.taskDeletions = ["t-9"]
        batch.deletedProjectIDs = ["p-9"]
        XCTAssertFalse(batch.isEmpty)

        let changes = batch.cloudKitChanges(in: zoneID)
        XCTAssertEqual(changes.save.map(\.recordType), ["Area", "Project", "ProjectHeading", "Task", "Task"],
                       "Parents before children")
        let decoded = TaskZoneChangeDecoder.decode(records: changes.save,
                                                   deletedRecordNames: changes.delete.map(\.recordName),
                                                   token: nil, moreComing: false)
        XCTAssertEqual(decoded.taskTags, ["t-1": ["x"], "t-2": []], "Every pushed task carries the tag marker")
        XCTAssertEqual(decoded.taskLinksAuthoritative, ["t-1", "t-2"])
        XCTAssertEqual(decoded.deletedIDs, ["t-9"])
        XCTAssertEqual(decoded.deletedProjectIDs, ["p-9"])
        XCTAssertTrue(TaskSyncPushBatch().isEmpty)
    }

    func testChunking() {
        XCTAssertEqual(TaskSyncPushBatch.chunked(Array(1...7), size: 3), [[1, 2, 3], [4, 5, 6], [7]])
        XCTAssertEqual(TaskSyncPushBatch.chunked([Int](), size: 3), [])
        XCTAssertEqual(TaskSyncPushBatch.chunked([1, 2], size: 300), [[1, 2]])
    }
}
