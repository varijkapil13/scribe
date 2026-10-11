import CloudKit
import XCTest
@testable import Scribe

/// A pulled task can be filed under a project this device hasn't received
/// yet (out-of-order pulls, or a writer whose projects never synced). The
/// task lands in Inbox instead of the foreign key aborting the round, and the
/// intended project is kept until it arrives.
final class TaskSyncMissingProjectTests: XCTestCase {

    func testStoreFallsBackToInboxAndRemembersTheProject() throws {
        let store = TaskStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let remote = TodoTask(id: "r1", title: "From the Mac", projectId: "missing-project",
                              createdAt: Date(timeIntervalSince1970: 1),
                              updatedAt: Date(timeIntervalSince1970: 2))
        try store.upsertFromSync(remote)

        let local = try XCTUnwrap(store.fetchTask(id: "r1"))
        XCTAssertNil(local.projectId, "Shown in Inbox until the project syncs")
        XCTAssertEqual(local.title, "From the Mac")
        XCTAssertEqual(local.updatedAt, Date(timeIntervalSince1970: 2))
        // The intended project still travels on the next push.
        XCTAssertEqual(try store.tasksForSyncPush(ids: ["r1"]).first?.projectId, "missing-project")
        XCTAssertEqual(try store.taxonomySyncCounts().tasksAwaitingProject, 1)
    }

    func testStoreAppliesTaskInKnownProject() throws {
        let store = TaskStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let project = try store.createProject(name: "Work")
        let remote = TodoTask(id: "r2", title: "Filed", projectId: project.id,
                              createdAt: Date(timeIntervalSince1970: 1),
                              updatedAt: Date(timeIntervalSince1970: 2))
        try store.upsertFromSync(remote)
        XCTAssertEqual(try XCTUnwrap(store.fetchTask(id: "r2")).projectId, project.id)
        XCTAssertEqual(try store.taxonomySyncCounts().tasksAwaitingProject, 0)
    }

    func testCoordinatorKeepsMissingProjectTasksAndKeepsGoing() async throws {
        let store = TaskStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let stamp = Date(timeIntervalSince1970: 5)
        let orphan = TodoTask(id: "orphan", title: "Orphan", projectId: "nowhere", createdAt: stamp, updatedAt: stamp)
        let loose = TodoTask(id: "loose", title: "Loose", createdAt: stamp, updatedAt: stamp)
        let remote = MissingProjectFakeRemote(
            pull: .init(changed: [orphan, loose], deletedIDs: [], token: nil)
        )
        let cursor = MissingProjectFakeCursor()
        let coordinator = TaskSyncCoordinator(local: store, remote: remote, cursor: cursor,
                                              taxonomy: TaxonomySyncSetup(store: store, cursor: cursor))

        try await coordinator.pullRemoteChanges()

        XCTAssertEqual(coordinator.skippedForMissingProject, 1)
        XCTAssertNil(try XCTUnwrap(store.fetchTask(id: "orphan")).projectId)
        XCTAssertNotNil(try store.fetchTask(id: "loose"))
    }
}

private final class MissingProjectFakeRemote: RemoteTaskSyncing {
    let pull: CloudKitSyncService.PullResult
    init(pull: CloudKitSyncService.PullResult) { self.pull = pull }
    func ensureZone() async throws {}
    func pullChanges(since token: CKServerChangeToken?) async throws -> CloudKitSyncService.PullResult { pull }
    func push(upserts: [TodoTask], deletions: [String]) async throws -> Int { upserts.count }
}

private final class MissingProjectFakeCursor: SyncCursorStoring, TaxonomySyncCursorStoring {
    var changeToken: CKServerChangeToken?
    var lastPushDate: Date?
    var taxonomyLastPushDate: Date?
}
