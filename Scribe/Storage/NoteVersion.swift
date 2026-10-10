// Scribe/Storage/NoteVersion.swift
import Foundation
import GRDB

/// Why a note version snapshot was taken.
enum NoteVersionReason: String, Codable, CaseIterable, Sendable {
    /// Ordinary in-app save (throttled).
    case edit
    /// The file changed outside Scribe (Obsidian, iCloud, …) and the editor
    /// content / disk version was about to be replaced.
    case externalChange
    /// A Scribe-generated edit (summary, enhance, append) rewrote the note.
    case aiEdit
    /// A version was restored over the current content.
    case restore

    /// Forced reasons bypass the five-minute throttle.
    var bypassesThrottle: Bool { self != .edit }

    var label: String {
        switch self {
        case .edit:           return "Edit"
        case .externalChange: return "Changed outside Scribe"
        case .aiEdit:         return "Before Scribe edit"
        case .restore:        return "Before restore"
        }
    }
}

/// Index row for one snapshot of a note's previous content. The content
/// itself lives compressed in a file under the app's support folder (never
/// in the vault); `fileName` is relative to `NoteVersionStore.directory`.
struct NoteVersionRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var noteId: String
    var createdAt: Date
    var reason: String
    var title: String
    /// UTF-8 byte count of the uncompressed body.
    var byteCount: Int
    /// SHA-256 of the uncompressed body.
    var contentHash: String
    var fileName: String

    var versionReason: NoteVersionReason { NoteVersionReason(rawValue: reason) ?? .edit }
}

extension NoteVersionRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_versions"
}

// MARK: - Snapshot policy

/// Pure throttle: decides whether to snapshot `previousBody` before a save
/// replaces it with `newBody`.
enum NoteVersionPolicy {
    /// At most one throttled snapshot per note per this interval.
    nonisolated static let throttleInterval: TimeInterval = 5 * 60

    nonisolated static func shouldSnapshot(
        previousBody: String,
        newBody: String,
        previousHash: String,
        reason: NoteVersionReason,
        lastSnapshotAt: Date?,
        lastSnapshotHash: String?,
        now: Date
    ) -> Bool {
        // Nothing changes, or nothing worth keeping.
        guard previousBody != newBody else { return false }
        guard !previousBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Already the newest snapshot.
        if let lastSnapshotHash, lastSnapshotHash == previousHash { return false }
        if reason.bypassesThrottle { return true }
        guard let lastSnapshotAt else { return true }
        return now.timeIntervalSince(lastSnapshotAt) >= throttleInterval
    }
}

// MARK: - Retention

/// Pure retention selector:
/// - everything from the last 24 hours is kept;
/// - between 24 hours and 7 days, the newest version of each hour is kept;
/// - between 7 and 90 days, the newest version of each day is kept;
/// - anything older than 90 days is removed.
/// Versions dated in the future (clock changes) are kept.
enum NoteVersionRetention {
    struct Item: Equatable, Sendable {
        let id: String
        let createdAt: Date
    }

    nonisolated static let keepAllWindow: TimeInterval = 24 * 60 * 60
    nonisolated static let hourlyWindow: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let dailyWindow: TimeInterval = 90 * 24 * 60 * 60

    /// Ids of `items` the policy removes.
    nonisolated static func idsToDelete(_ items: [Item], now: Date, calendar: Calendar) -> Set<String> {
        var delete = Set<String>()
        var keptHourBuckets = Set<Date>()
        var keptDayBuckets = Set<Date>()
        // Newest first, so the first version seen in a bucket is the kept one.
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            let age = now.timeIntervalSince(item.createdAt)
            if age < keepAllWindow { continue }
            if age >= dailyWindow {
                delete.insert(item.id)
            } else if age < hourlyWindow {
                let bucket = calendar.dateInterval(of: .hour, for: item.createdAt)?.start ?? item.createdAt
                if !keptHourBuckets.insert(bucket).inserted { delete.insert(item.id) }
            } else {
                let bucket = calendar.startOfDay(for: item.createdAt)
                if !keptDayBuckets.insert(bucket).inserted { delete.insert(item.id) }
            }
        }
        return delete
    }
}
