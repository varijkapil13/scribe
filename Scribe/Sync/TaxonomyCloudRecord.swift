import CloudKit
import Foundation

/// Wire format for the task taxonomy — areas, projects and project headings —
/// as `CKRecord`s in the same 'Tasks' zone as `TaskCloudRecord`, plus the
/// task-record `tags` field. Pure + synchronous, so every mapping is
/// unit-testable without a container.
///
/// Record names carry a per-kind prefix ("taxonomy.project.<id>") so a
/// deletion — which CloudKit reports by record id only — is classified
/// without a lookup, and can never be mistaken for a task id by a client
/// that predates taxonomy sync (it just deletes nothing).
///
/// Backward compatibility: older clients ignore the unknown record types and
/// the unknown task fields; every reader here defaults absent optional fields.
enum TaxonomyCloudRecord {
    static let areaRecordType = "Area"
    static let projectRecordType = "Project"
    static let headingRecordType = "ProjectHeading"

    static func recordType(for kind: TaxonomySyncKind) -> String {
        switch kind {
        case .area: return areaRecordType
        case .project: return projectRecordType
        case .heading: return headingRecordType
        }
    }

    static func recordNamePrefix(for kind: TaxonomySyncKind) -> String {
        "taxonomy.\(kind.rawValue)."
    }

    static func recordName(for kind: TaxonomySyncKind, id: String) -> String {
        recordNamePrefix(for: kind) + id
    }

    static func recordID(for kind: TaxonomySyncKind, id: String, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(for: kind, id: id), zoneID: zoneID)
    }

    /// The taxonomy kind + row id a record name encodes, or nil for a task
    /// (or any other) record name.
    static func parse(recordName: String) -> (kind: TaxonomySyncKind, id: String)? {
        for kind in TaxonomySyncKind.allCases {
            let prefix = recordNamePrefix(for: kind)
            if recordName.hasPrefix(prefix), recordName.count > prefix.count {
                return (kind, String(recordName.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// Row id for a record of `kind`: the name minus its prefix (a bare name
    /// is accepted too, for robustness).
    private static func rowID(of record: CKRecord, kind: TaxonomySyncKind) -> String {
        let name = record.recordID.recordName
        if let parsed = parse(recordName: name), parsed.kind == kind { return parsed.id }
        return name
    }

    private static func freshRecord(_ kind: TaxonomySyncKind, id: String, in zoneID: CKRecordZone.ID) -> CKRecord {
        CKRecord(recordType: recordType(for: kind), recordID: recordID(for: kind, id: id, in: zoneID))
    }

    // MARK: Area

    static func makeRecord(area entry: TaxonomySyncEntry<TaskArea>, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = freshRecord(.area, id: entry.item.id, in: zoneID)
        record["name"] = entry.item.name
        record["sortOrder"] = entry.item.sortOrder
        record["symbol"] = entry.item.symbol.map { $0 as any CKRecordValueProtocol }
        record["updatedAt"] = entry.updatedAt
        return record
    }

    static func area(from record: CKRecord) -> TaxonomySyncEntry<TaskArea>? {
        guard record.recordType == areaRecordType,
              let name = record["name"] as? String,
              let updatedAt = record["updatedAt"] as? Date
        else { return nil }
        let area = TaskArea(
            id: rowID(of: record, kind: .area),
            name: name,
            sortOrder: (record["sortOrder"] as? Int) ?? 0,
            symbol: record["symbol"] as? String
        )
        return TaxonomySyncEntry(item: area, updatedAt: updatedAt)
    }

    // MARK: Project

    static func makeRecord(project entry: TaxonomySyncEntry<Project>, in zoneID: CKRecordZone.ID) -> CKRecord {
        let project = entry.item
        let record = freshRecord(.project, id: project.id, in: zoneID)
        record["name"] = project.name
        record["color"] = project.color.map { $0 as any CKRecordValueProtocol }
        record["icon"] = project.icon.map { $0 as any CKRecordValueProtocol }
        record["createdAt"] = project.createdAt
        record["sortOrder"] = project.sortOrder
        record["areaId"] = project.areaId.map { $0 as any CKRecordValueProtocol }
        record["updatedAt"] = entry.updatedAt
        return record
    }

    static func project(from record: CKRecord) -> TaxonomySyncEntry<Project>? {
        guard record.recordType == projectRecordType,
              let name = record["name"] as? String,
              let updatedAt = record["updatedAt"] as? Date
        else { return nil }
        let project = Project(
            id: rowID(of: record, kind: .project),
            name: name,
            color: record["color"] as? String,
            icon: record["icon"] as? String,
            createdAt: (record["createdAt"] as? Date) ?? updatedAt,
            sortOrder: (record["sortOrder"] as? Int) ?? 0,
            areaId: record["areaId"] as? String
        )
        return TaxonomySyncEntry(item: project, updatedAt: updatedAt)
    }

    // MARK: Heading

    static func makeRecord(heading entry: TaxonomySyncEntry<ProjectHeading>, in zoneID: CKRecordZone.ID) -> CKRecord {
        let heading = entry.item
        let record = freshRecord(.heading, id: heading.id, in: zoneID)
        record["projectId"] = heading.projectId
        record["title"] = heading.title
        record["sortOrder"] = heading.sortOrder
        record["updatedAt"] = entry.updatedAt
        return record
    }

    static func heading(from record: CKRecord) -> TaxonomySyncEntry<ProjectHeading>? {
        guard record.recordType == headingRecordType,
              let projectId = record["projectId"] as? String,
              let updatedAt = record["updatedAt"] as? Date
        else { return nil }
        let heading = ProjectHeading(
            id: rowID(of: record, kind: .heading),
            projectId: projectId,
            title: (record["title"] as? String) ?? "",
            sortOrder: (record["sortOrder"] as? Int) ?? 0
        )
        return TaxonomySyncEntry(item: heading, updatedAt: updatedAt)
    }
}

// MARK: - Task tags

extension TaskCloudRecord {
    /// Normalized, sorted tag list on the Task record.
    static let tagsKey = "tags"
    /// Set (to `taxonomySchemaVersion`) by writers that sync tags and
    /// taxonomy. It tells "this task has no tags" apart from "this writer
    /// doesn't sync tags" — CloudKit may hand an empty list back as absent.
    static let taxonomySchemaKey = "taxonomySchema"
    static let taxonomySchemaVersion = 1

    /// Writes the task's tags (normalized like `TaskStore`, sorted) and the
    /// schema marker.
    static func applyTags(_ tags: [String], to record: CKRecord) {
        let list = TaskStore.normalisedTagList(tags).sorted()
        // `[String]` is a CloudKit list value (`CKRecordValueProtocol`).
        record[tagsKey] = list as any CKRecordValueProtocol
        record[taxonomySchemaKey] = taxonomySchemaVersion
    }

    /// The task's tags, or nil when the record says nothing about tags (an
    /// older writer): the caller then keeps the local tags.
    static func tags(from record: CKRecord) -> [String]? {
        let list = record[tagsKey] as? [String]
        let schema = (record[taxonomySchemaKey] as? Int) ?? 0
        if let list { return TaskStore.normalisedTagList(list).sorted() }
        return schema >= 1 ? [] : nil
    }
}

// MARK: - Zone change decoding / push encoding

/// Sorts one zone-changes fetch into a `PullResult` (records of every type,
/// deletions by record-name prefix). Pure, so the classification is tested.
enum TaskZoneChangeDecoder {

    static func decode(records: [CKRecord], deletedRecordNames: [String],
                       token: CKServerChangeToken?, moreComing: Bool) -> CloudKitSyncService.PullResult {
        var result = CloudKitSyncService.PullResult(changed: [], deletedIDs: [], token: token)
        result.moreComing = moreComing
        for record in records {
            switch record.recordType {
            case TaskCloudRecord.recordType:
                guard let task = TaskCloudRecord.task(from: record) else { continue }
                result.changed.append(task)
                if let tags = TaskCloudRecord.tags(from: record) { result.taskTags[task.id] = tags }
            case TaxonomyCloudRecord.areaRecordType:
                if let area = TaxonomyCloudRecord.area(from: record) { result.areas.append(area) }
            case TaxonomyCloudRecord.projectRecordType:
                if let project = TaxonomyCloudRecord.project(from: record) { result.projects.append(project) }
            case TaxonomyCloudRecord.headingRecordType:
                if let heading = TaxonomyCloudRecord.heading(from: record) { result.headings.append(heading) }
            default:
                continue
            }
        }
        for name in deletedRecordNames {
            guard let parsed = TaxonomyCloudRecord.parse(recordName: name) else {
                result.deletedIDs.append(name)
                continue
            }
            switch parsed.kind {
            case .area: result.deletedAreaIDs.append(parsed.id)
            case .project: result.deletedProjectIDs.append(parsed.id)
            case .heading: result.deletedHeadingIDs.append(parsed.id)
            }
        }
        return result
    }
}

/// Everything one round pushes: tasks (with tags), taxonomy rows, deletions.
struct TaskSyncPushBatch {
    var tasks: [TodoTask] = []
    /// Tags per pushed task id. A task listed here is written with the
    /// taxonomy marker (so an empty list really means "no tags").
    var taskTags: [String: [String]] = [:]
    var taskDeletions: [String] = []
    var areas: [TaxonomySyncEntry<TaskArea>] = []
    var projects: [TaxonomySyncEntry<Project>] = []
    var headings: [TaxonomySyncEntry<ProjectHeading>] = []
    var deletedAreaIDs: [String] = []
    var deletedProjectIDs: [String] = []
    var deletedHeadingIDs: [String] = []

    var isEmpty: Bool {
        tasks.isEmpty && taskDeletions.isEmpty && areas.isEmpty && projects.isEmpty && headings.isEmpty
            && deletedAreaIDs.isEmpty && deletedProjectIDs.isEmpty && deletedHeadingIDs.isEmpty
    }

    /// The records to save and ids to delete, in apply order (areas,
    /// projects, headings, tasks).
    func cloudKitChanges(in zoneID: CKRecordZone.ID) -> (save: [CKRecord], delete: [CKRecord.ID]) {
        var save: [CKRecord] = []
        save += areas.map { TaxonomyCloudRecord.makeRecord(area: $0, in: zoneID) }
        save += projects.map { TaxonomyCloudRecord.makeRecord(project: $0, in: zoneID) }
        save += headings.map { TaxonomyCloudRecord.makeRecord(heading: $0, in: zoneID) }
        for task in tasks {
            let record = TaskCloudRecord.makeRecord(from: task, in: zoneID)
            if let tags = taskTags[task.id] { TaskCloudRecord.applyTags(tags, to: record) }
            save.append(record)
        }
        var delete: [CKRecord.ID] = []
        delete += deletedHeadingIDs.map { TaxonomyCloudRecord.recordID(for: .heading, id: $0, in: zoneID) }
        delete += deletedProjectIDs.map { TaxonomyCloudRecord.recordID(for: .project, id: $0, in: zoneID) }
        delete += deletedAreaIDs.map { TaxonomyCloudRecord.recordID(for: .area, id: $0, in: zoneID) }
        delete += taskDeletions.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        return (save, delete)
    }

    /// Splits `items` into request-sized chunks (CloudKit rejects a modify
    /// request with more than 400 items).
    static func chunked<Element>(_ items: [Element], size: Int) -> [[Element]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
