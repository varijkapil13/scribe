import XCTest
import GRDB
@testable import Scribe

final class ScribeBackupArchiverTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeBackupArchiverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A vault with two notes, one attachment, a hidden folder and a symlink.
    private func makeVault(named name: String, noteText: String) throws -> URL {
        let vault = workspace.appendingPathComponent(name, isDirectory: true)
        try write(noteText, to: vault.appendingPathComponent("Note.md"))
        try write("# Daily", to: vault.appendingPathComponent("Daily/2027-01-15.md"))
        try write("PNG", to: vault.appendingPathComponent("attachments/note-1/image.png"))
        try write("{}", to: vault.appendingPathComponent(".obsidian/app.json"))
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("link.md"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        return vault
    }

    private func makeDatabase(taskTitle: String) throws -> DatabaseManager {
        let manager = try DatabaseManager(path: ":memory:")
        try TaskStore(databaseManager: manager).createTask(title: taskTitle)
        return manager
    }

    private func taskTitles(_ manager: DatabaseManager) throws -> [String] {
        try manager.database.read { db in try String.fetchAll(db, sql: "SELECT title FROM tasks ORDER BY title") }
    }

    private func sources(database: DatabaseManager, vault: URL?, support: [URL] = [], settings: Data? = nil) -> ScribeBackupSources {
        ScribeBackupSources(
            database: database,
            vaultRoot: vault,
            supportFiles: support,
            settingsPlist: settings,
            settingsCount: settings == nil ? 0 : 1,
            appVersion: "9.9",
            appBuild: "99"
        )
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Stage

    func testStageWritesLayoutAndManifest() throws {
        let database = try makeDatabase(taskTitle: "Backed up task")
        let vault = try makeVault(named: "Vault", noteText: "# Hello")
        let vocabulary = workspace.appendingPathComponent("support/vocabulary.md")
        try write("- Scribe", to: vocabulary)
        let settings = try ScribeBackupSettings.encode(["selectedLanguage": "en-US"])
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)

        let manifest = try ScribeBackupArchiver.stage(
            sources: sources(database: database, vault: vault, support: [vocabulary], settings: settings),
            into: staging, now: now, automatic: false
        )

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("scribe.sqlite").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("Vault/Note.md").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("Vault/.obsidian/app.json").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("Support/vocabulary.md").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("settings.plist").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("Vault/link.md").path),
                     "Symlinks are left out of backups")
        // The live vault keeps its link.
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: vault.appendingPathComponent("link.md").path))

        XCTAssertEqual(manifest.counts.notes, 2)
        XCTAssertEqual(manifest.counts.attachments, 1)
        XCTAssertEqual(manifest.counts.vaultFiles, 4)
        XCTAssertEqual(manifest.counts.tasks, 1)
        XCTAssertEqual(manifest.counts.sessions, 0)
        XCTAssertEqual(manifest.counts.settings, 1)
        XCTAssertEqual(manifest.skippedSymlinks, 1)
        XCTAssertEqual(manifest.supportFiles, ["vocabulary.md"])
        XCTAssertFalse(manifest.schemaMigrations.isEmpty)

        let onDisk = try ScribeBackupManifest.decode(Data(contentsOf: staging.appendingPathComponent("manifest.json")))
        XCTAssertEqual(onDisk, manifest)
    }

    func testStageWithoutVaultStillProducesARestorableBackup() throws {
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try ScribeBackupArchiver.stage(
            sources: sources(database: try makeDatabase(taskTitle: "T"), vault: nil),
            into: staging, now: now, automatic: true
        )
        let inspection = try ScribeBackupArchiver.inspect(
            extractedRoot: staging,
            knownMigrations: try ScribeBackupArchiver.knownMigrationIdentifiers()
        )
        XCTAssertTrue(inspection.canRestore, "\(inspection.issues)")
        XCTAssertTrue(inspection.manifest.isAutomatic)
    }

    // MARK: - Inspect

    func testInspectAcceptsAStagedBackup() throws {
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try ScribeBackupArchiver.stage(
            sources: sources(database: try makeDatabase(taskTitle: "T"), vault: try makeVault(named: "V", noteText: "x")),
            into: staging, now: now, automatic: false
        )
        let known = try ScribeBackupArchiver.knownMigrationIdentifiers()
        let inspection = try ScribeBackupArchiver.inspect(extractedRoot: staging, knownMigrations: known)
        XCTAssertEqual(inspection.issues, [])
        XCTAssertEqual(Set(inspection.databaseMigrations), known)
    }

    func testInspectRejectsADatabaseFromANewerScribe() throws {
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try ScribeBackupArchiver.stage(
            sources: sources(database: try makeDatabase(taskTitle: "T"), vault: nil),
            into: staging, now: now, automatic: false
        )
        let queue = try DatabaseQueue(path: staging.appendingPathComponent("scribe.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999_future')")
        }

        let inspection = try ScribeBackupArchiver.inspect(
            extractedRoot: staging,
            knownMigrations: try ScribeBackupArchiver.knownMigrationIdentifiers()
        )
        XCTAssertFalse(inspection.canRestore)
        XCTAssertEqual(inspection.issues, [.newerDatabaseSchema(unknownMigrations: ["v999_future"])])
    }

    func testInspectReportsMissingPieces() throws {
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try ScribeBackupArchiver.stage(
            sources: sources(database: try makeDatabase(taskTitle: "T"), vault: nil),
            into: staging, now: now, automatic: false
        )
        try FileManager.default.removeItem(at: staging.appendingPathComponent("scribe.sqlite"))
        try FileManager.default.removeItem(at: staging.appendingPathComponent("Vault"))

        let inspection = try ScribeBackupArchiver.inspect(extractedRoot: staging, knownMigrations: [])
        XCTAssertTrue(inspection.issues.contains(.missingFile("scribe.sqlite")))
        XCTAssertTrue(inspection.issues.contains(.missingFile("Vault")))
    }

    func testInspectRejectsAFolderWithoutAManifest() {
        XCTAssertThrowsError(try ScribeBackupArchiver.inspect(extractedRoot: workspace, knownMigrations: [])) { error in
            XCTAssertEqual(error as? ScribeBackupError, .notABackup)
        }
    }

    func testLocateManifestRootFindsAWrappedFolder() throws {
        let wrapped = workspace.appendingPathComponent("extract/Scribe Backup 2027", isDirectory: true)
        try write("{}", to: wrapped.appendingPathComponent("manifest.json"))
        let found = ScribeBackupArchiver.locateManifestRoot(in: workspace.appendingPathComponent("extract"))
        XCTAssertEqual(found?.lastPathComponent, "Scribe Backup 2027")
        XCTAssertNil(ScribeBackupArchiver.locateManifestRoot(in: workspace.appendingPathComponent("nowhere")))
    }

    // MARK: - Restore

    func testRestoreMovesCurrentDataAsideAndInstallsTheBackup() throws {
        // Backup side.
        let backupVocabulary = workspace.appendingPathComponent("backup-support/vocabulary.md")
        try write("- From backup", to: backupVocabulary)
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try ScribeBackupArchiver.stage(
            sources: sources(
                database: try makeDatabase(taskTitle: "From backup"),
                vault: try makeVault(named: "BackupVault", noteText: "# From backup"),
                support: [backupVocabulary],
                settings: try ScribeBackupSettings.encode(["selectedLanguage": "de-DE"])
            ),
            into: staging, now: now, automatic: false
        )
        let inspection = try ScribeBackupArchiver.inspect(
            extractedRoot: staging,
            knownMigrations: try ScribeBackupArchiver.knownMigrationIdentifiers()
        )
        XCTAssertTrue(inspection.canRestore, "\(inspection.issues)")

        // Live side.
        let live = try makeDatabase(taskTitle: "Live task")
        let liveVault = workspace.appendingPathComponent("LiveVault", isDirectory: true)
        try write("# Live note", to: liveVault.appendingPathComponent("Live.md"))
        let supportDirectory = workspace.appendingPathComponent("AppSupport", isDirectory: true)
        try write("- Live", to: supportDirectory.appendingPathComponent("vocabulary.md"))
        let targets = ScribeRestoreTargets(
            database: live,
            vaultRoot: liveVault,
            supportDirectory: supportDirectory,
            safetyCopiesDirectory: supportDirectory.appendingPathComponent("Restore Safety Copies", isDirectory: true)
        )
        let currentSettings = try ScribeBackupSettings.encode(["selectedLanguage": "en-GB"])

        let outcome = try ScribeBackupArchiver.restore(
            inspection, into: targets, currentSettingsPlist: currentSettings, now: now
        )

        let fm = FileManager.default
        // Backup installed.
        XCTAssertEqual(try taskTitles(live), ["From backup"])
        XCTAssertEqual(try String(contentsOf: liveVault.appendingPathComponent("Note.md"), encoding: .utf8), "# From backup")
        XCTAssertFalse(fm.fileExists(atPath: liveVault.appendingPathComponent("Live.md").path))
        XCTAssertEqual(try String(contentsOf: supportDirectory.appendingPathComponent("vocabulary.md"), encoding: .utf8), "- From backup")
        let restoredSettings = try ScribeBackupSettings.decodeRestorable(try XCTUnwrap(outcome.settingsPlist))
        XCTAssertEqual(restoredSettings["selectedLanguage"] as? String, "de-DE")

        // Previous data preserved, never deleted.
        let safety = outcome.safetyCopyFolder
        XCTAssertTrue(safety.lastPathComponent.hasPrefix("Before Restore "))
        XCTAssertEqual(try String(contentsOf: safety.appendingPathComponent("Vault/Live.md"), encoding: .utf8), "# Live note")
        XCTAssertEqual(try String(contentsOf: safety.appendingPathComponent("Support/vocabulary.md"), encoding: .utf8), "- Live")
        XCTAssertTrue(fm.fileExists(atPath: safety.appendingPathComponent("settings.plist").path))
        let previous = try DatabaseQueue(path: safety.appendingPathComponent("scribe.sqlite").path)
        let previousTitles = try previous.read { db in try String.fetchAll(db, sql: "SELECT title FROM tasks") }
        XCTAssertEqual(previousTitles, ["Live task"])
    }

    func testRestoreRefusesAnInvalidBackup() throws {
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try ScribeBackupArchiver.stage(
            sources: sources(database: try makeDatabase(taskTitle: "T"), vault: nil),
            into: staging, now: now, automatic: false
        )
        // Nothing is "known", so the schema looks newer than this build.
        let inspection = try ScribeBackupArchiver.inspect(extractedRoot: staging, knownMigrations: [])
        XCTAssertFalse(inspection.canRestore)

        let live = try makeDatabase(taskTitle: "Live task")
        let liveVault = workspace.appendingPathComponent("LiveVault", isDirectory: true)
        try write("# Live", to: liveVault.appendingPathComponent("Live.md"))
        let targets = ScribeRestoreTargets(
            database: live,
            vaultRoot: liveVault,
            supportDirectory: workspace.appendingPathComponent("AppSupport", isDirectory: true),
            safetyCopiesDirectory: workspace.appendingPathComponent("Safety", isDirectory: true)
        )
        XCTAssertThrowsError(try ScribeBackupArchiver.restore(inspection, into: targets, currentSettingsPlist: nil, now: now))
        XCTAssertEqual(try taskTitles(live), ["Live task"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveVault.appendingPathComponent("Live.md").path))
    }

    func testUniqueFolderAvoidsCollisions() throws {
        let first = ScribeBackupArchiver.uniqueFolder(named: "Before Restore X", in: workspace)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = ScribeBackupArchiver.uniqueFolder(named: "Before Restore X", in: workspace)
        XCTAssertEqual(second.lastPathComponent, "Before Restore X 2")
    }

    // MARK: - Archive round trip

    func testArchiveRoundTrip() throws {
        let destination = workspace.appendingPathComponent("Out/Test.scribebackup")
        let written = try ScribeBackupArchiver.createArchive(
            sources: sources(
                database: try makeDatabase(taskTitle: "Round trip"),
                vault: try makeVault(named: "Vault", noteText: "# Round trip")
            ),
            destination: destination, now: now, automatic: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let root = try ScribeBackupArchiver.extractArchive(
            destination,
            into: workspace.appendingPathComponent("extracted", isDirectory: true)
        )
        let inspection = try ScribeBackupArchiver.inspect(
            extractedRoot: root,
            knownMigrations: try ScribeBackupArchiver.knownMigrationIdentifiers()
        )
        XCTAssertTrue(inspection.canRestore, "\(inspection.issues)")
        XCTAssertEqual(inspection.manifest, written)
        XCTAssertEqual(
            try String(contentsOf: inspection.vaultURL.appendingPathComponent("Note.md"), encoding: .utf8),
            "# Round trip"
        )
    }

    func testExtractRejectsNonArchives() throws {
        let bogus = workspace.appendingPathComponent("bogus.scribebackup")
        try write("not a zip", to: bogus)
        XCTAssertThrowsError(try ScribeBackupArchiver.extractArchive(bogus, into: workspace.appendingPathComponent("x"))) { error in
            XCTAssertEqual(error as? ScribeBackupError, .notABackup)
        }
    }

    // MARK: - Archive safety

    func testUnsafeEntryNames() {
        let names = [
            "Scribe Backup/manifest.json",
            "Scribe Backup/Vault/Note.md",
            "../escape.txt",
            "Scribe Backup/../../escape.txt",
            "/etc/passwd",
            "~/x",
            "",
            "Scribe Backup/..hidden.md",
        ]
        XCTAssertEqual(
            ScribeBackupArchiveSafety.unsafeEntryNames(names),
            ["../escape.txt", "Scribe Backup/../../escape.txt", "/etc/passwd", "~/x"]
        )
    }

    func testSymlinkDetectionInLongListing() {
        let clean = """
        Archive:  test.zip
        Zip file size: 1234 bytes, number of entries: 2
        drwxr-xr-x  2.1 unx        0 bx stor 27-Jan-15 08:00 Scribe Backup/
        -rw-r--r--  2.1 unx      120 tx defN 27-Jan-15 08:00 Scribe Backup/manifest.json
        2 files, 120 bytes uncompressed, 90 bytes compressed:  25.0%
        """
        XCTAssertFalse(ScribeBackupArchiveSafety.containsSymlinkEntries(longListing: clean))
        let withLink = clean + "\nlrwxr-xr-x  2.1 unx       10 bx stor 27-Jan-15 08:00 Scribe Backup/link\n"
        XCTAssertTrue(ScribeBackupArchiveSafety.containsSymlinkEntries(longListing: withLink))
    }
}
