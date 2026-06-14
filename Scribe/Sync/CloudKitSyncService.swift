import CloudKit
import Foundation

/// CloudKit private-database sync for the task layer (the half of Scribe's data
/// that has no file representation; notes sync via the iCloud-Drive vault).
///
/// ⚠️ DEVICE-VALIDATION REQUIRED. This compiles and is structured correctly,
/// but live behaviour can only be verified on real devices signed into iCloud
/// with the `iCloud.com.varij.scribe` container provisioned in the Apple
/// Developer account (see docs/ICLOUD-MULTIPLATFORM-DESIGN.md). The pure merge
/// policy (`SyncMergePolicy`) and the record mapping (`TaskCloudRecord`) are
/// unit-tested; the network operations below are not (CloudKit has no offline
/// test surface).
///
/// Off by default — gated on `UserDefaults` so we never touch a user's iCloud
/// without an explicit opt-in.
final class CloudKitSyncService {

    static let enabledDefaultsKey = "iCloudSyncEnabled"

    /// Whether the user has opted into iCloud task sync.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(containerIdentifier: String = "iCloud.com.varij.scribe") {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: "Tasks", ownerName: CKCurrentUserDefaultName)
    }

    /// Creates the custom zone if it doesn't exist yet. Custom zones are
    /// required for incremental (`recordZoneChanges`) sync.
    func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
    }

    // MARK: - Push

    /// Pushes local upserts + deletions to CloudKit. Upserts use
    /// `.changedKeys` so concurrent edits to different fields don't clobber.
    @discardableResult
    func push(upserts: [TodoTask], deletions: [String]) async throws -> Int {
        let records = upserts.map { TaskCloudRecord.makeRecord(from: $0, in: zoneID) }
        let deleteIDs = deletions.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let result = try await database.modifyRecords(
            saving: records,
            deleting: deleteIDs,
            savePolicy: .changedKeys
        )
        // Surface partial failures to the caller's logs without throwing the
        // whole batch away — a single conflicted record shouldn't lose the rest.
        var saved = 0
        for (_, outcome) in result.saveResults {
            switch outcome {
            case .success: saved += 1
            case .failure(let error):
                Log.storage.error("CloudKit push save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return saved
    }

    // MARK: - Pull

    /// One incremental fetch of remote changes since `token`. Returns the
    /// changed tasks, the ids deleted remotely, and the new change token to
    /// persist for the next call.
    struct PullResult {
        var changed: [TodoTask]
        var deletedIDs: [String]
        var token: CKServerChangeToken?
    }

    func pullChanges(since token: CKServerChangeToken?) async throws -> PullResult {
        let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)

        var changed: [TodoTask] = []
        for modification in changes.modificationResultsByID.values {
            if case .success(let mod) = modification, let task = TaskCloudRecord.task(from: mod.record) {
                changed.append(task)
            }
        }
        let deletedIDs = changes.deletions.map { $0.recordID.recordName }
        return PullResult(changed: changed, deletedIDs: deletedIDs, token: changes.changeToken)
    }
}
