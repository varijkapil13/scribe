import Foundation

/// One backup archive found in a backup folder.
struct ScribeBackupFileInfo: Equatable, Sendable {
    let url: URL
    let createdAt: Date
}

/// Pure naming + retention rules for backup archives.
///
/// Automatic backups are named `Scribe Auto Backup yyyy-MM-dd HHmmss.scribebackup`
/// and pruned to the newest N. Manual backups (`Scribe Backup …`) and any
/// other file in the folder are never selected for deletion — retention only
/// ever touches archives it can positively identify as its own.
enum ScribeBackupRetention {

    static let automaticPrefix = "Scribe Auto Backup "
    static let manualPrefix = "Scribe Backup "
    /// Bounds for the "keep the last N" setting.
    static let keepCountRange: ClosedRange<Int> = 1...60
    /// How often an automatic backup is wanted.
    static let automaticInterval: TimeInterval = 24 * 60 * 60
    /// Slack so a backup that ran at 09:05 yesterday is due again at 09:00
    /// today (the scheduler's tolerance means runs drift by minutes).
    static let dueSlack: TimeInterval = 60 * 60

    private static let stampFormat = "yyyy-MM-dd HHmmss"

    private nonisolated static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = stampFormat
        return formatter
    }

    /// `2026-10-10 091500` — the timestamp used in archive and folder names.
    nonisolated static func timestamp(for date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    /// File name for a new archive.
    nonisolated static func fileName(for date: Date, automatic: Bool, timeZone: TimeZone = .current) -> String {
        let prefix = automatic ? automaticPrefix : manualPrefix
        return "\(prefix)\(timestamp(for: date, timeZone: timeZone)).\(ScribeBackupManifest.fileExtension)"
    }

    /// The creation date encoded in an automatic backup's file name, or nil
    /// when the name isn't one of ours.
    nonisolated static func automaticBackupDate(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        let suffix = "." + ScribeBackupManifest.fileExtension
        guard name.hasPrefix(automaticPrefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(automaticPrefix.count).dropLast(suffix.count))
        guard stamp.count == stampFormat.count else { return nil }
        return formatter(timeZone: timeZone).date(from: stamp)
    }

    /// Clamps a user-entered keep count into ``keepCountRange``.
    nonisolated static func clampedKeepCount(_ value: Int) -> Int {
        min(max(value, keepCountRange.lowerBound), keepCountRange.upperBound)
    }

    /// The backups to delete so only the newest `keepCount` remain. The keep
    /// count is clamped to at least 1, so retention never removes every
    /// backup. Ties on date are broken by file name for determinism.
    nonisolated static func backupsToDelete(
        _ backups: [ScribeBackupFileInfo],
        keeping keepCount: Int
    ) -> [ScribeBackupFileInfo] {
        let keep = clampedKeepCount(keepCount)
        let newestFirst = backups.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        guard newestFirst.count > keep else { return [] }
        return Array(newestFirst.dropFirst(keep))
    }

    /// Automatic backups among `fileNames` (everything else is ignored).
    nonisolated static func automaticBackups(
        in folder: URL,
        fileNames: [String],
        timeZone: TimeZone = .current
    ) -> [ScribeBackupFileInfo] {
        fileNames.compactMap { name in
            guard let date = automaticBackupDate(fromFileName: name, timeZone: timeZone) else { return nil }
            return ScribeBackupFileInfo(url: folder.appendingPathComponent(name, isDirectory: false), createdAt: date)
        }
    }

    /// Whether an automatic backup should run now.
    nonisolated static func isBackupDue(
        lastBackupAt: Date?,
        now: Date,
        interval: TimeInterval = automaticInterval,
        slack: TimeInterval = dueSlack
    ) -> Bool {
        guard let lastBackupAt else { return true }
        // A last-backup date in the future means the clock moved backwards;
        // treat it as due rather than silently skipping backups for days.
        if lastBackupAt > now { return true }
        return now.timeIntervalSince(lastBackupAt) >= max(0, interval - slack)
    }
}
