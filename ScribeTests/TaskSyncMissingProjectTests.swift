import CloudKit
import XCTest
@testable import Scribe

/// Projects don't sync yet, so a pulled task can be filed under a project
/// this device doesn't have. That task is skipped instead of the foreign key
/// aborting the whole round.
final class TaskSyncMissingProjectTests: XCTestCase {

    func testStoreRefusesTaskInUnknownProjectWithoutWriting() throws {
        let store = TaskStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let remote = TodoTask(id: "r1", title: "From the Mac", projectId: "missing-project",
                              createdAt: Date(timeIntervalSince1970: 1),
                              updatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertThrowsError(try store.upsertFromSync(remote)) { error in
            guard case TaskStoreError.syncedTaskProjectMissing(let id)? = error as? TaskStoreError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(id, "missing-project")
        }
        XCTAssertNil(try store.fetchTask(id: "r1"))
    }

    func testStoreAppliesTaskInKnownProject() throws {
        let store = TaskStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let project = try store.createProject(name: "Work")
        let remote = TodoTask(id: "r2", title: "Filed", projectId: project.id,
                              createdAt: Date(timeIntervalSince1970: 1),
                              updatedAt: Date(timeIntervalSince1970: 2))
        try store.upsertFromSync(remote)
        XCTAssertEqual(try XCTUnwrap(store.fetchTask(id: "r2")).projectId, project.id)
    }

    func testCoordinatorSkipsMissingProjectTasksAndKeepsGoing() async throws {
        let store = TaskStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let stamp = Date(timeIntervalSince1970: 5)
        let orphan = TodoTask(id: "orphan", title: "Orphan", projectId: "nowhere", createdAt: stamp, updatedAt: stamp)
        let loose = TodoTask(id: "loose", title: "Loose", createdAt: stamp, updatedAt: stamp)
        let remote = MissingProjectFakeRemote(
            pull: .init(changed: [orphan, loose], deletedIDs: [], token: nil)
        )
        let coordinator = TaskSyncCoordinator(local: store, remote: remote, cursor: MissingProjectFakeCursor())

        try await coordinator.pullRemoteChanges()

        XCTAssertEqual(coordinator.skippedForMissingProject, 1)
        XCTAssertNil(try store.fetchTask(id: "orphan"))
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

private final class MissingProjectFakeCursor: SyncCursorStoring {
    var changeToken: CKServerChangeToken?
    var lastPushDate: Date?
}
