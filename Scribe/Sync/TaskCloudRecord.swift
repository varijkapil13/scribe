import CloudKit
import Foundation

/// Wire format for syncing a `TodoTask` as a CloudKit `CKRecord`. The mapping
/// is pure + synchronous (no network), so the round-trip is unit-testable; the
/// push/pull lives in `CloudKitSyncService`.
enum TaskCloudRecord {
    static let recordType = "Task"

    /// Builds a fresh record in `zoneID`. For updates, prefer `apply(_:to:)` on
    /// a server-fetched record so its change tag is preserved.
    static func makeRecord(from task: TodoTask, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: task.id, zoneID: zoneID)
        )
        apply(task, to: record)
        return record
    }

    /// Writes the task's syncable fields onto an existing record.
    static func apply(_ task: TodoTask, to record: CKRecord) {
        record["title"] = task.title
        record["notes"] = task.notes
        record["createdAt"] = task.createdAt
        record["updatedAt"] = task.updatedAt
        record["sortOrder"] = task.sortOrder
        record["isPinned"] = task.isPinned ? 1 : 0
        record["projectId"] = task.projectId.map { $0 as any CKRecordValueProtocol }
        record["priority"] = task.priority.map { $0.rawValue as any CKRecordValueProtocol }
        record["dueAt"] = task.dueAt.map { $0 as any CKRecordValueProtocol }
        record["remindAt"] = task.remindAt.map { $0 as any CKRecordValueProtocol }
        record["recurrenceRule"] = task.recurrenceRule.map { $0 as any CKRecordValueProtocol }
        record["completedAt"] = task.completedAt.map { $0 as any CKRecordValueProtocol }
        record["cancelledAt"] = task.cancelledAt.map { $0 as any CKRecordValueProtocol }
        record["sourceSessionId"] = task.sourceSessionId.map { $0 as any CKRecordValueProtocol }
        record["sourceActionItemId"] = task.sourceActionItemId.map { $0 as any CKRecordValueProtocol }
    }

    /// Reconstructs a `TodoTask` from a record. Returns `nil` if the record
    /// isn't a well-formed Task (wrong type or missing required fields).
    static func task(from record: CKRecord) -> TodoTask? {
        guard record.recordType == recordType,
              let title = record["title"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date
        else { return nil }

        return TodoTask(
            id: record.recordID.recordName,
            title: title,
            notes: record["notes"] as? String ?? "",
            projectId: record["projectId"] as? String,
            priority: (record["priority"] as? String).flatMap(TodoTask.Priority.init(rawValue:)),
            dueAt: record["dueAt"] as? Date,
            remindAt: record["remindAt"] as? Date,
            recurrenceRule: record["recurrenceRule"] as? String,
            completedAt: record["completedAt"] as? Date,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortOrder: (record["sortOrder"] as? Int) ?? 0,
            sourceSessionId: record["sourceSessionId"] as? String,
            sourceActionItemId: record["sourceActionItemId"] as? String,
            cancelledAt: record["cancelledAt"] as? Date,
            isPinned: ((record["isPinned"] as? Int) ?? 0) != 0
        )
    }
}
