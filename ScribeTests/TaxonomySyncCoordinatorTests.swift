import CloudKit
import XCTest
@testable import Scribe

/// End-to-end taxonomy sync between two simulated devices (each an in-memory
/// database + `TaskStore`) through a fake CloudKit zone that stores real
/// `CKRecord`s built by the production encoder and decodes them with the
/// production decoder.
final class TaxonomySyncCoordinatorTests: XCTestCase {

    // MARK: - Fake CloudKit

    /// One shared private zone: the latest record per name plus an ordered
    /// change log, so each device pulls only what changed since its last pull.
    private final class FakeCloudZone {
        enum Change { case saved(String), deleted(String) }
        let zoneID = CKRecordZone.ID(zoneName: "Tasks", ownerName: CKCurrentUserDefaultName)
        var records: [String: CKRecord] = [:]
        var log: [Change] = []

        func record(_ kind: TaxonomySyncKind, _ id: String) -> CKRecord? {
            records[TaxonomyCloudRecord.recordName(for: kind, id: id)]
        }
    }

    /// A device's view of the zone (`RemoteTaskSyncing`).
    private final class FakeCloudClient: RemoteTaskSyncing {
        let zone: FakeCloudZone
        /// Changes per pull page (nil = everything in one page).
        var pageSize: Int?
        /// Deliver new changes newest-first (children before parents).
        var reverseOrder = false
        private var seen = 0
        private var queue: [FakeCloudZone.Change] = []
        private(set) var pushedBatches: [TaskSyncPushBatch] = []

        init(zone: FakeCloudZone) { self.zone = zone }

        func ensureZone() async throws {}

        func pullChanges(since token: CKServerChangeToken?) async throws -> CloudKitSyncService.PullResult {
            let fresh = Array(zone.log[seen...])
            seen = zone.log.count
            queue += reverseOrder ? fresh.reversed() : fresh
            let take = min(pageSize ?? queue.count, queue.count)
            let page = Array(queue.prefix(take))
            queue.removeFirst(take)
            var saved: [CKRecord] = []
            var deleted: [String] = []
            for change in page {
                switch change {
                case .saved(let name): if let record = zone.records[name] { saved.append(record) }
                case .deleted(let name): deleted.append(name)
                }
            }
            return TaskZoneChangeDecoder.decode(records: saved, deletedRecordNames: deleted,
                                                token: nil, moreComing: !queue.isEmpty)
        }

        func push(upserts: [TodoTask], deletions: [String]) async throws -> Int {
            XCTFail("Taxonomy rounds push batches")
            return 0
        }

        func push(batch: TaskSyncPushBatch) async throws -> Int {
            pushedBatches.append(batch)
            let changes = batch.cloudKitChanges(in: zone.zoneID)
            for record in changes.save {
                zone.records[record.recordID.recordName] = record
                zone.log.append(.saved(record.recordID.recordName))
            }
            for id in changes.delete {
                zone.records[id.recordName] = nil
                zone.log.append(.deleted(id.recordName))
            }
            return changes.save.count
        }
    }

    private final class FakeCursor: SyncCursorStoring, TaxonomySyncCursorStoring {
        var changeToken: CKServerChangeToken?
        var lastPushDate: Date?
        var taxonomyLastPushDate: Date?
    }

    /// One simulated device.
    private final class Device {
        let manager: DatabaseManager
        let store: TaskStore
        let cloud: FakeCloudClient
        let coordinator: TaskSyncCoordinator

        init(zone: FakeCloudZone) throws {
            manager = try DatabaseManager(path: ":memory:")
            store = TaskStore(databaseManager: manager)
            cloud = FakeCloudClient(zone: zone)
            let cursor = FakeCursor()
            coordinator = TaskSyncCoordinator(local: store, remote: cloud, cursor: cursor,
                                              taxonomy: TaxonomySyncSetup(store: store, cursor: cursor))
        }

        /// One round, as `TaskSyncCoordinator.sync()` runs it (minus the
        /// opt-in gate).
        func sync() async throws {
            try await coordinator.pullRemoteChanges()
            try await coordinator.pushLocalChanges()
        }

        func setStamp(_ kind: TaxonomySyncKind, _ id: String, _ date: Date) throws {
            try manager.database.write { db in
                try db.execute(sql: "UPDATE \(kind.tableName) SET updatedAt = ? WHERE id = ?", arguments: [date, id])
            }
        }
    }

    /// Lets the clock move past the previous push cursor (stamps are stored
    /// at millisecond precision).
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    // MARK: - Propagation

    func testTaxonomyAndTagsReachTheOtherDevice() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)

        let area = try mac.store.createArea(name: "Work", symbol: "briefcase")
        let project = try mac.store.createProject(name: "Launch", color: "#FF8800", icon: "rocket")
        try mac.store.setArea(area.id, forProject: project.id)
        let heading = try mac.store.createHeading(in: project.id, title: "Phase 1")
        let filed = try mac.store.createTask(title: "Write copy", projectId: project.id,
                                             tags: ["Writing", "urgent"], headingId: heading.id)
        let loose = try mac.store.createTask(title: "Call", tags: ["phone"], areaId: area.id)

        try await mac.sync()
        try await phone.sync()

        XCTAssertEqual(try phone.store.fetchAreas().map(\.name), ["Work"])
        XCTAssertEqual(try phone.store.fetchAreas().first?.symbol, "briefcase")
        let phoneProject = try XCTUnwrap(phone.store.fetchProjects().first)
        XCTAssertEqual(phoneProject.id, project.id)
        XCTAssertEqual(phoneProject.color, "#FF8800")
        XCTAssertEqual(phoneProject.areaId, area.id)
        XCTAssertEqual(try phone.store.headings(in: project.id).map(\.title), ["Phase 1"])

        let phoneFiled = try XCTUnwrap(phone.store.fetchTask(id: filed.id))
        XCTAssertEqual(phoneFiled.projectId, project.id)
        XCTAssertEqual(phoneFiled.headingId, heading.id)
        XCTAssertEqual(try phone.store.tags(for: filed.id), ["urgent", "writing"])
        XCTAssertEqual(try XCTUnwrap(phone.store.fetchTask(id: loose.id)).areaId, area.id)
        XCTAssertEqual(try phone.store.tags(for: loose.id), ["phone"])
        XCTAssertEqual(try phone.store.taxonomySyncCounts().waitingReferences, 0)
    }

    func testPulledRowsAreNotEchoedBackAndOnlyChangedRowsArePushed() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let project = try mac.store.createProject(name: "P")
        let heading = try mac.store.createHeading(in: project.id, title: "H")
        _ = try mac.store.createTask(title: "T", projectId: project.id)
        try await settle()
        try await mac.sync()
        try await settle()

        try await phone.sync()
        XCTAssertTrue(phone.cloud.pushedBatches.isEmpty, "Nothing new on the phone to push")

        try await settle()
        try mac.store.renameHeading(id: heading.id, title: "Renamed")
        try await mac.sync()
        let last = try XCTUnwrap(mac.cloud.pushedBatches.last)
        XCTAssertEqual(last.headings.map(\.item.title), ["Renamed"])
        XCTAssertTrue(last.projects.isEmpty)
        XCTAssertTrue(last.tasks.isEmpty)

        try await phone.sync()
        XCTAssertEqual(try phone.store.headings(in: project.id).map(\.title), ["Renamed"])
    }

    // MARK: - Last writer wins

    func testConcurrentProjectEditsResolveToTheNewestWrite() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        var project = try mac.store.createProject(name: "Original")
        try await mac.sync()
        try await phone.sync()

        // Both rename offline; the phone's edit is the later one.
        project.name = "Mac name"
        try mac.store.updateProject(project)
        try mac.setStamp(.project, project.id, Date().addingTimeInterval(10))
        var phoneCopy = try XCTUnwrap(phone.store.fetchProjects().first)
        phoneCopy.name = "Phone name"
        try phone.store.updateProject(phoneCopy)
        try phone.setStamp(.project, project.id, Date().addingTimeInterval(20))

        try await mac.sync()     // pushes "Mac name"
        try await phone.sync()   // keeps its newer edit, pushes "Phone name"
        try await mac.sync()     // takes the newer remote

        XCTAssertEqual(try mac.store.fetchProjects().map(\.name), ["Phone name"])
        XCTAssertEqual(try phone.store.fetchProjects().map(\.name), ["Phone name"])
    }

    func testAnOlderRemoteEditDoesNotOverwriteANewerLocalOne() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let area = try mac.store.createArea(name: "Original")
        try await mac.sync()
        try await phone.sync()

        var newer = try XCTUnwrap(phone.store.fetchAreas().first)
        newer.name = "Phone (newer)"
        try phone.store.updateArea(newer)
        try phone.setStamp(.area, area.id, Date().addingTimeInterval(60))

        var older = area
        older.name = "Mac (older)"
        try mac.store.updateArea(older)
        try mac.setStamp(.area, area.id, Date().addingTimeInterval(30))
        try await mac.sync()
        try await phone.sync()

        XCTAssertEqual(try phone.store.fetchAreas().map(\.name), ["Phone (newer)"])
    }

    // MARK: - Deletions

    func testDeletingProjectsPropagatesBothWaysWithoutLosingTasks() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let one = try mac.store.createProject(name: "One")
        let two = try mac.store.createProject(name: "Two")
        let heading = try mac.store.createHeading(in: one.id, title: "H")
        let taskOne = try mac.store.createTask(title: "In one", projectId: one.id, headingId: heading.id)
        let taskTwo = try mac.store.createTask(title: "In two", projectId: two.id)
        try await mac.sync()
        try await phone.sync()
        XCTAssertEqual(try phone.store.fetchProjects().count, 2)

        try await settle()
        try mac.store.deleteProject(id: one.id)
        try phone.store.deleteProject(id: two.id)
        try await mac.sync()
        try await phone.sync()
        try await mac.sync()

        for device in [mac, phone] {
            XCTAssertTrue(try device.store.fetchProjects().isEmpty)
            XCTAssertEqual(try device.store.headings(in: one.id), [])
            let first = try XCTUnwrap(device.store.fetchTask(id: taskOne.id))
            let second = try XCTUnwrap(device.store.fetchTask(id: taskTwo.id))
            XCTAssertNil(first.projectId)
            XCTAssertNil(first.headingId)
            XCTAssertNil(second.projectId)
        }
        XCTAssertNil(zone.record(.project, one.id))
        XCTAssertNil(zone.record(.project, two.id))
        XCTAssertNil(zone.record(.heading, heading.id), "Headings deleted with their project leave the server too")
    }

    func testDeletingAnAreaPropagates() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let area = try mac.store.createArea(name: "Gone")
        let project = try mac.store.createProject(name: "Stays")
        try mac.store.setArea(area.id, forProject: project.id)
        try await mac.sync()
        try await phone.sync()

        try await settle()
        try phone.store.deleteArea(id: area.id)
        try await phone.sync()
        try await mac.sync()

        XCTAssertTrue(try mac.store.fetchAreas().isEmpty)
        XCTAssertEqual(try mac.store.fetchProjects().map(\.name), ["Stays"])
        XCTAssertNil(try mac.store.fetchProjects().first?.areaId)
    }

    // MARK: - Out-of-order pulls

    func testChildrenArrivingBeforeParentsResolveWithinTheRound() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let area = try mac.store.createArea(name: "A")
        let project = try mac.store.createProject(name: "P")
        try mac.store.setArea(area.id, forProject: project.id)
        let heading = try mac.store.createHeading(in: project.id, title: "H")
        let task = try mac.store.createTask(title: "T", projectId: project.id, headingId: heading.id)
        try await mac.sync()

        // One record per page, newest first: the task lands before its
        // heading, project and area.
        phone.cloud.pageSize = 1
        phone.cloud.reverseOrder = true
        try await phone.sync()

        let synced = try XCTUnwrap(phone.store.fetchTask(id: task.id))
        XCTAssertEqual(synced.projectId, project.id)
        XCTAssertEqual(synced.headingId, heading.id)
        XCTAssertEqual(try phone.store.fetchProjects().first?.areaId, area.id)
        XCTAssertEqual(try phone.store.taxonomySyncCounts().waitingReferences, 0)
    }

    func testDanglingReferencesAreKeptAndResolvedOnTheNextPull() async throws {
        let device = try Device(zone: FakeCloudZone())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TodoTask(id: "t-1", title: "Early", projectId: "p-1", createdAt: stamp, updatedAt: stamp,
                            headingId: "h-1")
        let scripted = ScriptedRemote(pages: [
            .init(changed: [task], deletedIDs: [], token: nil, taskTags: ["t-1": ["x"]]),
            .init(changed: [], deletedIDs: [], token: nil,
                  projects: [.init(item: Project(id: "p-1", name: "Late", createdAt: stamp), updatedAt: stamp)],
                  headings: [.init(item: ProjectHeading(id: "h-1", projectId: "p-1", title: "Late H"), updatedAt: stamp)])
        ])
        let cursor = FakeCursor()
        let coordinator = TaskSyncCoordinator(local: device.store, remote: scripted, cursor: cursor,
                                              taxonomy: TaxonomySyncSetup(store: device.store, cursor: cursor))

        try await coordinator.pullRemoteChanges()
        XCTAssertEqual(coordinator.skippedForMissingProject, 1)
        XCTAssertNil(try XCTUnwrap(device.store.fetchTask(id: "t-1")).projectId, "In Inbox meanwhile")

        // A local edit in between still pushes the intended project.
        try device.store.setPinned(true, for: "t-1")
        try await coordinator.pushLocalChanges()
        let pushed = try XCTUnwrap(scripted.pushed.last?.tasks.first { $0.id == "t-1" })
        XCTAssertEqual(pushed.projectId, "p-1")
        XCTAssertEqual(pushed.headingId, "h-1")
        XCTAssertTrue(pushed.isPinned)

        try await coordinator.pullRemoteChanges()
        XCTAssertEqual(coordinator.skippedForMissingProject, 0)
        let resolved = try XCTUnwrap(device.store.fetchTask(id: "t-1"))
        XCTAssertEqual(resolved.projectId, "p-1")
        XCTAssertEqual(resolved.headingId, "h-1")
        XCTAssertTrue(resolved.isPinned, "The local edit survives resolution")
        XCTAssertEqual(try device.store.tags(for: "t-1"), ["x"])
    }

    // MARK: - Tags

    func testRecordWithoutTagsKeepsLocalTags() async throws {
        let device = try Device(zone: FakeCloudZone())
        let task = try device.store.createTask(title: "Mine", tags: ["keep"])
        var legacy = task
        legacy.title = "Edited on an older client"
        legacy.updatedAt = task.updatedAt.addingTimeInterval(60)
        let scripted = ScriptedRemote(pages: [.init(changed: [legacy], deletedIDs: [], token: nil)])
        let cursor = FakeCursor()
        let coordinator = TaskSyncCoordinator(local: device.store, remote: scripted, cursor: cursor,
                                              taxonomy: TaxonomySyncSetup(store: device.store, cursor: cursor))

        try await coordinator.pullRemoteChanges()

        XCTAssertEqual(try XCTUnwrap(device.store.fetchTask(id: task.id)).title, "Edited on an older client")
        XCTAssertEqual(try device.store.tags(for: task.id), ["keep"])
    }

    func testTagEditsSyncAndClearing() async throws {
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let task = try mac.store.createTask(title: "T", tags: ["a"])
        try await mac.sync()
        try await phone.sync()
        XCTAssertEqual(try phone.store.tags(for: task.id), ["a"])

        try await settle()
        try phone.store.setTags(["b", "c"], for: task.id)
        try await phone.sync()
        try await mac.sync()
        XCTAssertEqual(try mac.store.tags(for: task.id), ["b", "c"])

        try await settle()
        try mac.store.setTags([], for: task.id)
        try await mac.sync()
        try await phone.sync()
        XCTAssertEqual(try phone.store.tags(for: task.id), [])
    }

    func testFirstTaxonomyRoundUnionsTagsOfTheSameTaskVersion() async throws {
        // Upgrade scenario: both devices hold the same task version (synced
        // before tags did), each with tags the other never saw.
        let zone = FakeCloudZone()
        let mac = try Device(zone: zone)
        let phone = try Device(zone: zone)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let shared = TodoTask(id: "shared", title: "Same version", createdAt: stamp, updatedAt: stamp)
        try mac.store.applyRemoteTask(shared, tags: ["from-mac"])
        try phone.store.applyRemoteTask(shared, tags: ["from-phone"])

        try await mac.sync()
        try await phone.sync()   // tie → union, stamped so it propagates
        try await mac.sync()

        XCTAssertEqual(try phone.store.tags(for: "shared"), ["from-mac", "from-phone"])
        XCTAssertEqual(try mac.store.tags(for: "shared"), ["from-mac", "from-phone"])
    }
}

/// Returns scripted pull pages (then empty pages) and records pushes.
private final class ScriptedRemote: RemoteTaskSyncing {
    private var pages: [CloudKitSyncService.PullResult]
    private(set) var pushed: [TaskSyncPushBatch] = []

    init(pages: [CloudKitSyncService.PullResult]) { self.pages = pages }

    func ensureZone() async throws {}

    func pullChanges(since token: CKServerChangeToken?) async throws -> CloudKitSyncService.PullResult {
        pages.isEmpty ? .init(changed: [], deletedIDs: [], token: nil) : pages.removeFirst()
    }

    func push(upserts: [TodoTask], deletions: [String]) async throws -> Int { upserts.count }

    func push(batch: TaskSyncPushBatch) async throws -> Int {
        pushed.append(batch)
        return batch.tasks.count
    }
}
