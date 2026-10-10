import Foundation
import GRDB

// MARK: - Inputs / outputs

/// Everything a backup reads. Built by `ScribeBackupEnvironment.makeSources`
/// in the app and by hand in tests.
struct ScribeBackupSources: Sendable {
    var database: DatabaseManager
    /// The notes vault root (attachments and templates live inside it).
    var vaultRoot: URL?
    /// Small app-support files copied into `Support/` (only names on
    /// ``ScribeBackupArchiver/supportFileAllowlist`` are ever restored).
    var supportFiles: [URL]
    /// Pre-encoded `settings.plist` (see ScribeBackupSettings), or nil.
    var settingsPlist: Data?
    var settingsCount: Int
    var appVersion: String
    var appBuild: String
}

/// An extracted, validated backup ready to show in the restore summary.
struct ScribeBackupInspection: Sendable {
    let manifest: ScribeBackupManifest
    /// Folder containing `manifest.json`.
    let root: URL
    /// Migration identifiers found in the backup's database.
    let databaseMigrations: [String]
    /// Empty when the backup can be restored.
    let issues: [ScribeBackupValidationIssue]

    var canRestore: Bool { issues.isEmpty }
    var databaseURL: URL { root.appendingPathComponent(ScribeBackupManifest.databaseFileName, isDirectory: false) }
    var vaultURL: URL { root.appendingPathComponent(ScribeBackupManifest.vaultFolderName, isDirectory: true) }
    var supportURL: URL { root.appendingPathComponent(ScribeBackupManifest.supportFolderName, isDirectory: true) }
    var settingsURL: URL { root.appendingPathComponent(ScribeBackupManifest.settingsFileName, isDirectory: false) }
}

/// Where a restore writes.
struct ScribeRestoreTargets: Sendable {
    /// The live database; its contents are replaced through SQLite's backup
    /// API, so open connections stay valid.
    var database: DatabaseManager
    var vaultRoot: URL
    /// `~/Library/Application Support/Scribe`.
    var supportDirectory: URL
    /// Parent of the timestamped "Before Restore …" safety-copy folders.
    var safetyCopiesDirectory: URL
    /// The session-audio root (`SessionAudioStorage.defaultRoot()`). Audio
    /// folders the restored database no longer references are moved into the
    /// safety copy, because the launch-time orphan sweep would otherwise
    /// delete them. Nil skips that step (tests without audio).
    var audioRoot: URL? = nil
}

struct ScribeRestoreOutcome: Sendable {
    /// Where the pre-restore data was moved. Never deleted by Scribe.
    let safetyCopyFolder: URL
    /// The backup's settings plist, applied by the caller on the main actor.
    let settingsPlist: Data?
}

enum ScribeBackupError: LocalizedError, Equatable {
    case notABackup
    case toolFailed(tool: String, status: Int32)
    case cannotRestore([ScribeBackupValidationIssue])

    var errorDescription: String? {
        switch self {
        case .notABackup:
            return "This file isn't a Scribe backup."
        case .toolFailed(let tool, let status):
            return "Couldn't read the backup archive (\(tool) exited with status \(status))."
        case .cannotRestore(let issues):
            return issues.map(\.message).joined(separator: "\n")
        }
    }
}

// MARK: - Archiver

/// Creates, opens and restores `.scribebackup` archives. Synchronous and
/// nonisolated: callers run it off the main actor (Task.detached / the
/// background-activity scheduler).
enum ScribeBackupArchiver {

    /// Support files a restore may write. Anything else in an archive's
    /// `Support/` folder is ignored.
    static let supportFileAllowlist: Set<String> = ["vocabulary.md"]

    // MARK: Create

    /// Writes a complete archive to `destination` (replacing an existing file
    /// only once the new archive is fully written next to it).
    @discardableResult
    nonisolated static func createArchive(
        sources: ScribeBackupSources,
        destination: URL,
        now: Date,
        automatic: Bool
    ) throws -> ScribeBackupManifest {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("ScribeBackup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let folderName = (automatic ? ScribeBackupRetention.automaticPrefix : ScribeBackupRetention.manualPrefix)
            + ScribeBackupRetention.timestamp(for: now)
        let staging = scratch.appendingPathComponent(folderName, isDirectory: true)
        let manifest = try stage(sources: sources, into: staging, now: now, automatic: automatic)

        let zipped = scratch.appendingPathComponent("archive.zip", isDirectory: false)
        try zipDirectory(staging, to: zipped)
        try install(zipped, at: destination)
        return manifest
    }

    /// Fills `staging` with the backup layout and returns its manifest.
    @discardableResult
    nonisolated static func stage(
        sources: ScribeBackupSources,
        into staging: URL,
        now: Date,
        automatic: Bool
    ) throws -> ScribeBackupManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // 1. Consistent database snapshot (SQLite online backup).
        let databaseURL = staging.appendingPathComponent(ScribeBackupManifest.databaseFileName, isDirectory: false)
        try backupDatabase(sources.database.database, toFileAt: databaseURL)
        let databaseFacts = try readDatabaseFacts(at: databaseURL)

        // 2. Vault (notes, attachments, templates, hidden folders).
        let vaultDestination = staging.appendingPathComponent(ScribeBackupManifest.vaultFolderName, isDirectory: true)
        var skippedSymlinks = 0
        if let vaultRoot = sources.vaultRoot, fm.fileExists(atPath: vaultRoot.path) {
            try fm.copyItem(at: vaultRoot, to: vaultDestination)
            skippedSymlinks = try removeSymlinks(under: vaultDestination)
        } else {
            try fm.createDirectory(at: vaultDestination, withIntermediateDirectories: true)
        }
        let vaultCounts = countVault(at: vaultDestination)

        // 3. Support files.
        let supportDestination = staging.appendingPathComponent(ScribeBackupManifest.supportFolderName, isDirectory: true)
        try fm.createDirectory(at: supportDestination, withIntermediateDirectories: true)
        var supportNames: [String] = []
        for file in sources.supportFiles where fm.fileExists(atPath: file.path) {
            let name = file.lastPathComponent
            try fm.copyItem(at: file, to: supportDestination.appendingPathComponent(name, isDirectory: false))
            supportNames.append(name)
        }

        // 4. Settings.
        if let settings = sources.settingsPlist {
            try settings.write(
                to: staging.appendingPathComponent(ScribeBackupManifest.settingsFileName, isDirectory: false),
                options: .atomic
            )
        }

        // 5. Manifest last, so a manifest only exists for a complete folder.
        let manifest = ScribeBackupManifest(
            formatVersion: ScribeBackupManifest.currentFormatVersion,
            appVersion: sources.appVersion,
            appBuild: sources.appBuild,
            createdAt: now,
            isAutomatic: automatic,
            counts: ScribeBackupManifest.Counts(
                notes: vaultCounts.notes,
                attachments: vaultCounts.attachments,
                vaultFiles: vaultCounts.files,
                sessions: databaseFacts.sessions,
                tasks: databaseFacts.tasks,
                settings: sources.settingsPlist == nil ? 0 : sources.settingsCount
            ),
            schemaMigrations: databaseFacts.migrations,
            supportFiles: supportNames,
            skippedSymlinks: skippedSymlinks
        )
        try ScribeBackupManifest.encode(manifest).write(
            to: staging.appendingPathComponent(ScribeBackupManifest.fileName, isDirectory: false),
            options: .atomic
        )
        return manifest
    }

    // MARK: Open

    /// Extracts `archive` into `folder` (which should be a fresh scratch
    /// folder) after checking its entry list, and returns the folder that
    /// holds `manifest.json`.
    nonisolated static func extractArchive(_ archive: URL, into folder: URL) throws -> URL {
        // Refuse path traversal / links before writing anything.
        let names: [String]
        do {
            names = try runTool("/usr/bin/unzip", ["-Z1", archive.path])
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        } catch {
            throw ScribeBackupError.notABackup
        }
        let unsafe = ScribeBackupArchiveSafety.unsafeEntryNames(names)
        if !unsafe.isEmpty {
            throw ScribeBackupError.cannotRestore([.unsafeArchiveEntries(unsafe)])
        }
        let longListing = try runTool("/usr/bin/unzip", ["-Z", archive.path])
        if ScribeBackupArchiveSafety.containsSymlinkEntries(longListing: longListing) {
            throw ScribeBackupError.cannotRestore([.unsafeArchiveEntries(["symbolic link"])])
        }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        guard let root = locateManifestRoot(in: folder) else { throw ScribeBackupError.notABackup }
        return root
    }

    /// The folder holding `manifest.json`: `folder` itself or one of its
    /// direct subfolders (zips usually wrap everything in one folder).
    nonisolated static func locateManifestRoot(in folder: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(ScribeBackupManifest.fileName).path) {
            return folder
        }
        let children = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = children
            .filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in candidates {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, fm.fileExists(atPath: child.appendingPathComponent(ScribeBackupManifest.fileName).path) {
                return child
            }
        }
        return nil
    }

    /// Reads and validates an extracted backup.
    nonisolated static func inspect(extractedRoot root: URL, knownMigrations: Set<String>) throws -> ScribeBackupInspection {
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent(ScribeBackupManifest.fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ScribeBackupManifest.decode(data) else {
            throw ScribeBackupError.notABackup
        }

        var issues: [ScribeBackupValidationIssue] = []
        var databaseMigrations: [String] = manifest.schemaMigrations
        var databaseReadable = false
        let databaseURL = root.appendingPathComponent(ScribeBackupManifest.databaseFileName, isDirectory: false)
        if !fm.fileExists(atPath: databaseURL.path) {
            issues.append(.missingFile(ScribeBackupManifest.databaseFileName))
        } else {
            do {
                let queue = try openReadOnly(databaseURL)
                let check = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
                if check != "ok" {
                    issues.append(.damagedDatabase(check ?? "integrity check failed"))
                } else {
                    databaseMigrations = try queue.read { db in try appliedMigrations(db) }
                    databaseReadable = true
                }
            } catch {
                issues.append(.damagedDatabase(error.localizedDescription))
            }
        }

        var isDirectory: ObjCBool = false
        let vaultPath = root.appendingPathComponent(ScribeBackupManifest.vaultFolderName, isDirectory: true).path
        if !fm.fileExists(atPath: vaultPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            issues.append(.missingFile(ScribeBackupManifest.vaultFolderName))
        }

        issues.append(contentsOf: manifest.validationIssues(
            knownMigrations: knownMigrations,
            databaseMigrations: databaseReadable ? databaseMigrations : nil
        ).filter { issue in
            // A damaged/missing database already explains itself.
            databaseReadable || issue != .missingDatabaseSchema
        })

        return ScribeBackupInspection(
            manifest: manifest,
            root: root,
            databaseMigrations: databaseMigrations,
            issues: issues
        )
    }

    /// Every migration identifier this build registers.
    nonisolated static func knownMigrationIdentifiers() throws -> Set<String> {
        let probe = try DatabaseManager(path: ":memory:")
        return Set(try probe.database.read { db in try appliedMigrations(db) })
    }

    // MARK: Restore

    /// Replaces the live data with the backup's.
    ///
    /// Nothing is deleted: the current database is snapshotted, and the
    /// current vault and support files are *moved* into a timestamped
    /// "Before Restore …" folder before the backup's copies are put in place.
    /// Any failure puts the original data back.
    nonisolated static func restore(
        _ inspection: ScribeBackupInspection,
        into targets: ScribeRestoreTargets,
        currentSettingsPlist: Data?,
        now: Date
    ) throws -> ScribeRestoreOutcome {
        guard inspection.canRestore else { throw ScribeBackupError.cannotRestore(inspection.issues) }
        let fm = FileManager.default

        let safety = uniqueFolder(
            named: "Before Restore \(ScribeBackupRetention.timestamp(for: now))",
            in: targets.safetyCopiesDirectory
        )
        try fm.createDirectory(at: safety, withIntermediateDirectories: true)

        // 1. Snapshot the live database before anything changes.
        let safetyDatabase = safety.appendingPathComponent(ScribeBackupManifest.databaseFileName, isDirectory: false)
        try backupDatabase(targets.database.database, toFileAt: safetyDatabase)

        // 2. Current settings.
        if let currentSettingsPlist {
            try currentSettingsPlist.write(
                to: safety.appendingPathComponent(ScribeBackupManifest.settingsFileName, isDirectory: false),
                options: .atomic
            )
        }

        // 3. Move the current vault aside, then copy the backup's in.
        let safetyVault = safety.appendingPathComponent(ScribeBackupManifest.vaultFolderName, isDirectory: true)
        let hadVault = fm.fileExists(atPath: targets.vaultRoot.path)
        if hadVault {
            try fm.moveItem(at: targets.vaultRoot, to: safetyVault)
        }
        func rollBackVault() {
            if fm.fileExists(atPath: targets.vaultRoot.path) {
                // Only ever the copy made from the backup archive.
                try? fm.removeItem(at: targets.vaultRoot)
            }
            if hadVault {
                try? fm.moveItem(at: safetyVault, to: targets.vaultRoot)
            }
        }
        do {
            try fm.createDirectory(
                at: targets.vaultRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: inspection.vaultURL, to: targets.vaultRoot)
        } catch {
            rollBackVault()
            throw error
        }

        // 4. Support files, 5. audio the backup doesn't know, 6. database contents.
        var movedSupport: [(live: URL, aside: URL)] = []
        var installedSupport: [URL] = []
        var movedAudio: [(live: URL, aside: URL)] = []
        var databaseTouched = false
        do {
            let safetySupport = safety.appendingPathComponent(ScribeBackupManifest.supportFolderName, isDirectory: true)
            for name in inspection.manifest.supportFiles where supportFileAllowlist.contains(name) {
                let source = inspection.supportURL.appendingPathComponent(name, isDirectory: false)
                guard fm.fileExists(atPath: source.path) else { continue }
                let live = targets.supportDirectory.appendingPathComponent(name, isDirectory: false)
                if fm.fileExists(atPath: live.path) {
                    try fm.createDirectory(at: safetySupport, withIntermediateDirectories: true)
                    let aside = safetySupport.appendingPathComponent(name, isDirectory: false)
                    try fm.moveItem(at: live, to: aside)
                    movedSupport.append((live: live, aside: aside))
                }
                try fm.createDirectory(at: targets.supportDirectory, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: live)
                installedSupport.append(live)
            }

            let backupQueue = try openReadOnly(inspection.databaseURL)

            // Session audio folders are named by session id, and the launch
            // sweep deletes any id the database doesn't know. Recordings made
            // after the backup would be lost, so move them aside too.
            if let audioRoot = targets.audioRoot {
                let restoredIds = try backupQueue.read { db -> Set<String> in
                    guard try db.tableExists("sessions") else { return [] }
                    return Set(try String.fetchAll(db, sql: "SELECT id FROM sessions"))
                }
                let safetyAudio = safety.appendingPathComponent("Audio", isDirectory: true)
                for folder in unreferencedAudioFolders(in: audioRoot, knownSessionIds: restoredIds) {
                    try fm.createDirectory(at: safetyAudio, withIntermediateDirectories: true)
                    let aside = safetyAudio.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
                    try fm.moveItem(at: folder, to: aside)
                    movedAudio.append((live: folder, aside: aside))
                }
            }

            databaseTouched = true
            try backupQueue.backup(to: targets.database.database)
        } catch {
            if databaseTouched, let original = try? openReadOnly(safetyDatabase) {
                try? original.backup(to: targets.database.database)
            }
            for entry in movedAudio { try? fm.moveItem(at: entry.aside, to: entry.live) }
            for url in installedSupport { try? fm.removeItem(at: url) }
            for entry in movedSupport { try? fm.moveItem(at: entry.aside, to: entry.live) }
            rollBackVault()
            throw error
        }

        var settings: Data?
        if fm.fileExists(atPath: inspection.settingsURL.path) {
            settings = try? Data(contentsOf: inspection.settingsURL)
        }
        return ScribeRestoreOutcome(safetyCopyFolder: safety, settingsPlist: settings)
    }

    // MARK: - Helpers

    private nonisolated static func backupDatabase(_ source: DatabaseQueue, toFileAt url: URL) throws {
        let destination = try DatabaseQueue(path: url.path)
        try source.backup(to: destination)
    }

    private nonisolated static func openReadOnly(_ url: URL) throws -> DatabaseQueue {
        var configuration = GRDB.Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    nonisolated static func appliedMigrations(_ db: Database) throws -> [String] {
        guard try db.tableExists("grdb_migrations") else { return [] }
        return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
    }

    private struct DatabaseFacts {
        var migrations: [String]
        var sessions: Int
        var tasks: Int
    }

    private nonisolated static func readDatabaseFacts(at url: URL) throws -> DatabaseFacts {
        let queue = try openReadOnly(url)
        return try queue.read { db in
            DatabaseFacts(
                migrations: try appliedMigrations(db),
                sessions: try rowCount(of: "sessions", in: db),
                tasks: try rowCount(of: "tasks", in: db)
            )
        }
    }

    /// `table` is always one of the literal names above, never user input.
    private nonisolated static func rowCount(of table: String, in db: Database) throws -> Int {
        guard try db.tableExists(table) else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    private struct VaultCounts {
        var notes = 0
        var attachments = 0
        var files = 0
    }

    private nonisolated static func countVault(at root: URL) -> VaultCounts {
        var counts = VaultCounts()
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return counts }
        while let relative = enumerator.nextObject() as? String {
            guard (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeRegular else { continue }
            counts.files += 1
            if relative.hasPrefix("attachments/") {
                counts.attachments += 1
            } else if (relative as NSString).pathExtension.lowercased() == "md" {
                counts.notes += 1
            }
        }
        return counts
    }

    /// Deletes symbolic links inside a *staged copy* of the vault (never the
    /// live vault). Returns how many were removed.
    private nonisolated static func removeSymlinks(under root: URL) throws -> Int {
        var links: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            while let relative = enumerator.nextObject() as? String {
                if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
                    links.append(relative)
                }
            }
        }
        for relative in links {
            try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
        }
        return links.count
    }

    /// UUID-named folders directly under `root` whose name isn't a known
    /// session id — exactly what `SessionAudioStorage.removeOrphanFolders`
    /// would delete at the next launch.
    nonisolated static func unreferencedAudioFolders(in root: URL, knownSessionIds: Set<String>) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { entry in
            let name = entry.lastPathComponent
            guard UUID(uuidString: name) != nil, !knownSessionIds.contains(name) else { return false }
            return (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A folder URL under `parent` that doesn't exist yet (`name`, `name 2`, …).
    nonisolated static func uniqueFolder(named name: String, in parent: URL) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    /// Zips `directory` (as the archive's single top-level folder) using the
    /// system's coordinated "for uploading" representation.
    private nonisolated static func zipDirectory(_ directory: URL, to destination: URL) throws {
        let box = ScribeBackupErrorBox()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinationError
        ) { zippedURL in
            do {
                try FileManager.default.copyItem(at: zippedURL, to: destination)
            } catch {
                box.error = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let error = box.error { throw error }
    }

    /// Moves a finished archive into place: written next to the destination
    /// first, then swapped in, so an existing file is only replaced by a
    /// complete archive.
    private nonisolated static func install(_ archive: URL, at destination: URL) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        try fm.copyItem(at: archive, to: partial)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Runs a system tool and returns its standard output.
    @discardableResult
    private nonisolated static func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting so a large listing can't fill the pipe and stall.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScribeBackupError.toolFailed(tool: (path as NSString).lastPathComponent, status: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Carries an error out of NSFileCoordinator's accessor block.
private final class ScribeBackupErrorBox: @unchecked Sendable {
    var error: Error?
}
