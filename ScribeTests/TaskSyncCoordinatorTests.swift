import CloudKit
import XCTest
@testable import Scribe

final class TaskSyncCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeLocal: LocalTaskSyncing {
        var sides: [String: SyncMergePolicy.Side]
        var tasksByID: [String: TodoTask]
        private(set) var upserted: [TodoTask] = []
        private(set) var deleted: [String] = []

        init(sides: [String: SyncMergePolicy.Side] = [:], tasks: [TodoTask] = []) {
            self.sides = sides
            self.tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        }
        func localTaskSides() throws -> [String: SyncMergePolicy.Side] { sides }
        func tasks(forIDs ids: [String]) throws -> [TodoTask] { ids.compactMap { tasksByID[$0] } }
        func upsertFromSync(_ task: TodoTask) throws { upserted.append(task) }
        func applyRemoteDelete(id: String) throws { deleted.append(id) }
    }

    private final class FakeRemote: RemoteTaskSyncing {
        var pull: CloudKitSyncService.PullResult
        private(set) var pushedUpserts: [TodoTask] = []
        private(set) var pushedDeletions: [String] = []
        init(pull: CloudKitSyncService.PullResult) { self.pull = pull }
        func ensureZone() async throws {}
        func pullChanges(since token: CKServerChangeToken?) async throws -> CloudKitSyncService.PullResult { pull }
        func push(upserts: [TodoTask], deletions: [String]) async throws -> Int {
            pushedUpserts = upserts
            pushedDeletions = deletions
            return upserts.count
        }
    }

    private final class FakeCursor: SyncCursorStoring {
        var changeToken: CKServerChangeToken?
        var lastPushDate: Date?
        init(lastPushDate: Date? = nil) { self.lastPushDate = lastPushDate }
    }

    private func task(_ id: String, updatedAt: Date) -> TodoTask {
        TodoTask(id: id, title: id, createdAt: updatedAt, updatedAt: updatedAt)
    }

    private let old = Date(timeIntervalSince1970: 1_000)
    private let recent = Date(timeIntervalSince1970: 2_000)

    // MARK: - Pull

    func testPullAppliesRemoteUpsertWhenRemoteNewer() async throws {
        let local = FakeLocal(sides: ["a": .init(updatedAt: old, isDeleted: false)])
        let remote = FakeRemote(pull: .init(changed: [task("a", updatedAt: recent)], deletedIDs: [], token: nil))
        let coord = TaskSyncCoordinator(local: local, remote: remote, cursor: FakeCursor())
        try await coord.pullRemoteChanges()
        XCTAssertEqual(local.upserted.map(\.id), ["a"])
    }

    func testPullSkipsRemoteUpsertWhenLocalNewer() async throws {
        let local = FakeLocal(sides: ["a": .init(updatedAt: recent, isDeleted: false)])
        let remote = FakeRemote(pull: .init(changed: [task("a", updatedAt: old)], deletedIDs: [], token: nil))
        let coord = TaskSyncCoordinator(local: local, remote: remote, cursor: FakeCursor())
        try await coord.pullRemoteChanges()
        XCTAssertTrue(local.upserted.isEmpty)
    }

    func testPullAppliesRemoteDeletions() async throws {
        let local = FakeLocal()
        let remote = FakeRemote(pull: .init(changed: [], deletedIDs: ["x", "y"], token: nil))
        let coord = TaskSyncCoordinator(local: local, remote: remote, cursor: FakeCursor())
        try await coord.pullRemoteChanges()
        XCTAssertEqual(local.deleted.sorted(), ["x", "y"])
    }

    // MARK: - Push

    func testPushSelectsOnlyChangesSinceCursor() async throws {
        let local = FakeLocal(
            sides: [
                "stale": .init(updatedAt: old, isDeleted: false),    // before cursor → skipped
                "fresh": .init(updatedAt: recent, isDeleted: false), // after cursor  → upsert
                "gone": .init(updatedAt: recent, isDeleted: true)    // after cursor  → delete
            ],
            tasks: [task("fresh", updatedAt: recent)]
        )
        let remote = FakeRemote(pull: .init(changed: [], deletedIDs: [], token: nil))
        let cursor = FakeCursor(lastPushDate: Date(timeIntervalSince1970: 1_500))
        let coord = TaskSyncCoordinator(local: local, remote: remote, cursor: cursor)

        try await coord.pushLocalChanges()

        XCTAssertEqual(remote.pushedUpserts.map(\.id), ["fresh"])
        XCTAssertEqual(remote.pushedDeletions, ["gone"])
        XCTAssertNotNil(cursor.lastPushDate)
    }

    func testFirstPushUploadsEverything() async throws {
        let local = FakeLocal(
            sides: ["a": .init(updatedAt: old, isDeleted: false)],
            tasks: [task("a", updatedAt: old)]
        )
        let remote = FakeRemote(pull: .init(changed: [], deletedIDs: [], token: nil))
        let coord = TaskSyncCoordinator(local: local, remote: remote, cursor: FakeCursor(lastPushDate: nil))
        try await coord.pushLocalChanges()
        XCTAssertEqual(remote.pushedUpserts.map(\.id), ["a"])
    }
}
