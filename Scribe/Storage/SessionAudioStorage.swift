// Scribe/Storage/SessionAudioStorage.swift
import Foundation

/// Resolves where retained session audio lives and cleans it up.
///
/// Layout: `<root>/<sessionId>/mic.m4a` and `<root>/<sessionId>/system.m4a`,
/// where `<root>` is `<storageLocation>/Audio` when the user picked a storage
/// location in Settings → Storage, otherwise
/// `~/Library/Application Support/Scribe/Audio`.
///
/// The absolute folder path is stored on the session row
/// (`sessions.audioDirectory`), so changing the storage location later never
/// orphans audio recorded under the old one.
///
/// Foundation-only so it stays iOS-safe (Storage/ is compiled into the iOS
/// target; iOS never records, but deleting a session must still compile).
enum SessionAudioStorage {

    /// UserDefaults key of the "Retain raw audio recordings" toggle.
    static let retainAudioKey = "retainAudio"
    /// UserDefaults key of the storage location picked in Settings → Storage.
    static let storageLocationKey = "storageLocation"

    static let micFileName = "mic.m4a"
    static let systemFileName = "system.m4a"
    static let audioFolderName = "Audio"

    // MARK: - Path resolution

    /// Pure resolver for the audio root. A non-blank `storageLocation` wins;
    /// otherwise audio goes under `<applicationSupport>/Scribe/Audio`.
    static func rootDirectory(storageLocation: String?, applicationSupport: URL) -> URL {
        let trimmed = storageLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent(audioFolderName, isDirectory: true)
        }
        return applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent(audioFolderName, isDirectory: true)
    }

    /// The audio root for the current settings.
    static func defaultRoot(defaults: UserDefaults = .standard) -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return rootDirectory(
            storageLocation: defaults.string(forKey: storageLocationKey),
            applicationSupport: appSupport
        )
    }

    /// The folder for one session's audio (not created).
    static func directory(forSessionId sessionId: String, root: URL) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true)
    }

    static func micFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(micFileName, isDirectory: false)
    }

    static func systemFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(systemFileName, isDirectory: false)
    }

    /// Whether the user wants session audio kept.
    static func isRetentionEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: retainAudioKey)
    }

    // MARK: - Cleanup

    /// Best-effort removal of a session's audio folder. Missing folders are
    /// fine; other failures are logged, never thrown — the DB row is the
    /// source of truth and is already gone (or about to be updated).
    static func removeDirectory(atPath path: String?) {
        guard let path, !path.isEmpty else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        do {
            try fm.removeItem(atPath: path)
        } catch {
            Log.storage.error("Failed to delete session audio at \(path, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Removes every folder directly under `root` whose name is a UUID that is
    /// not in `knownSessionIds` (audio left behind by sessions deleted outside
    /// Scribe's own delete paths, e.g. a note removed on disk). Anything that
    /// isn't a UUID-named folder is left alone, since `root` may sit inside a
    /// user-chosen folder. When `untouchedSince` is given, folders modified
    /// after that date are skipped (protects a recording that just started).
    /// Returns the number of folders removed.
    @discardableResult
    static func removeOrphanFolders(
        root: URL,
        knownSessionIds: Set<String>,
        untouchedSince: Date? = nil
    ) -> Int {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard UUID(uuidString: name) != nil, !knownSessionIds.contains(name) else { continue }
            let values = try? entry.resourceValues(forKeys: keys)
            guard values?.isDirectory == true else { continue }
            if let untouchedSince,
               let modified = values?.contentModificationDate,
               modified > untouchedSince {
                continue
            }
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                Log.storage.error("Failed to delete orphan audio folder \(name, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        return removed
    }

    // MARK: - Disk usage

    /// Total size in bytes of all regular files under `directory` (0 if it
    /// doesn't exist).
    static func diskUsage(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Combined disk usage of the current root plus any session folders that
    /// live elsewhere (recorded under a previous storage location).
    static func totalDiskUsage(root: URL, sessionDirectories: [String]) -> Int64 {
        let rootPath = root.standardizedFileURL.path
        var total = diskUsage(of: root)
        var seen = Set<String>()
        for path in sessionDirectories {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !standardized.hasPrefix(rootPath + "/"), seen.insert(standardized).inserted else { continue }
            total += diskUsage(of: URL(fileURLWithPath: standardized, isDirectory: true))
        }
        return total
    }
}
