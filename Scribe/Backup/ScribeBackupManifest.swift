import Foundation

/// The `manifest.json` at the root of every `.scribebackup` archive.
///
/// A backup archive is a zip of one folder:
///
/// ```
/// Scribe Backup 2026-10-10 091500/
///   manifest.json        ← this type
///   scribe.sqlite        ← consistent SQLite snapshot (GRDB backup API)
///   Vault/               ← the markdown notes vault, attachments + templates included
///   Support/             ← small app-support files (vocabulary.md)
///   settings.plist       ← exported preferences (see ScribeBackupSettings)
/// ```
///
/// Pure value type: encoding, decoding and validation have no side effects
/// so they are unit-tested directly (ScribeBackupManifestTests).
struct ScribeBackupManifest: Codable, Equatable, Sendable {

    /// What a backup contains, shown in the restore summary.
    struct Counts: Codable, Equatable, Sendable {
        /// Markdown files in the vault.
        var notes: Int
        /// Files under the vault's `attachments/` folder.
        var attachments: Int
        /// Every regular file in the vault (notes, attachments, templates, …).
        var vaultFiles: Int
        /// Recorded sessions (transcripts) in the database.
        var sessions: Int
        /// Tasks in the database.
        var tasks: Int
        /// Exported preference keys.
        var settings: Int
    }

    // MARK: Layout constants

    /// Bumped whenever the archive layout changes incompatibly. A backup with
    /// a higher format version than this build understands is refused.
    static let currentFormatVersion = 1
    static let fileExtension = "scribebackup"
    static let fileName = "manifest.json"
    static let databaseFileName = "scribe.sqlite"
    static let vaultFolderName = "Vault"
    static let supportFolderName = "Support"
    static let settingsFileName = "settings.plist"

    // MARK: Fields

    var formatVersion: Int
    /// `CFBundleShortVersionString` of the app that wrote the backup.
    var appVersion: String
    /// `CFBundleVersion` of the app that wrote the backup.
    var appBuild: String
    var createdAt: Date
    /// `true` for scheduled (automatic) backups.
    var isAutomatic: Bool
    var counts: Counts
    /// GRDB migration identifiers applied to the snapshot database. Used to
    /// refuse restoring a database written by a newer Scribe.
    var schemaMigrations: [String]
    /// File names stored under `Support/`.
    var supportFiles: [String]
    /// Vault symlinks left out of the backup (they are machine-specific and a
    /// restore never recreates links).
    var skippedSymlinks: Int

    // MARK: Coding

    nonisolated static func encode(_ manifest: ScribeBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    nonisolated static func decode(_ data: Data) throws -> ScribeBackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScribeBackupManifest.self, from: data)
    }

    // MARK: Validation

    /// Reasons a backup can't be restored by this build. Empty means OK.
    ///
    /// - Parameters:
    ///   - knownMigrations: every migration identifier this build registers.
    ///   - databaseMigrations: the identifiers actually found in the backup's
    ///     database (pass `schemaMigrations` when the database hasn't been
    ///     opened yet). Using what's really in the file means a hand-edited
    ///     manifest can't smuggle in a newer schema.
    nonisolated func validationIssues(
        knownMigrations: Set<String>,
        databaseMigrations: [String]? = nil
    ) -> [ScribeBackupValidationIssue] {
        var issues: [ScribeBackupValidationIssue] = []
        if formatVersion < 1 || formatVersion > Self.currentFormatVersion {
            issues.append(.unsupportedFormat(found: formatVersion, supported: Self.currentFormatVersion))
        }
        let applied = databaseMigrations ?? schemaMigrations
        if applied.isEmpty {
            issues.append(.missingDatabaseSchema)
        } else {
            let unknown = applied.filter { !knownMigrations.contains($0) }.sorted()
            if !unknown.isEmpty {
                issues.append(.newerDatabaseSchema(unknownMigrations: unknown))
            }
        }
        return issues
    }
}

/// Why a backup can't be restored. `message` is user-facing.
enum ScribeBackupValidationIssue: Equatable, Sendable {
    case unsupportedFormat(found: Int, supported: Int)
    case newerDatabaseSchema(unknownMigrations: [String])
    case missingDatabaseSchema
    case missingFile(String)
    case unsafeArchiveEntries([String])
    case damagedDatabase(String)

    var message: String {
        switch self {
        case .unsupportedFormat(let found, let supported):
            return "This backup uses format \(found), but this version of Scribe reads format \(supported). Update Scribe and try again."
        case .newerDatabaseSchema:
            return "This backup was made by a newer version of Scribe. Update Scribe and try again."
        case .missingDatabaseSchema:
            return "The backup's database is empty or isn't a Scribe database."
        case .missingFile(let name):
            return "The backup is incomplete: \(name) is missing."
        case .unsafeArchiveEntries(let names):
            let sample = names.prefix(3).joined(separator: ", ")
            return "The backup contains unexpected file paths (\(sample)) and was not opened."
        case .damagedDatabase(let detail):
            return "The backup's database is damaged (\(detail))."
        }
    }
}

// MARK: - Summary

extension ScribeBackupManifest {
    /// Multi-line, user-facing description of what the backup holds (shown
    /// in the restore confirmation). `formattedDate` is the creation date,
    /// already formatted for the user's locale.
    nonisolated func summaryText(formattedDate: String) -> String {
        func plural(_ count: Int, _ singular: String, _ pluralForm: String) -> String {
            "\(count) \(count == 1 ? singular : pluralForm)"
        }
        var lines = [
            "Created \(formattedDate)\(isAutomatic ? " (automatic)" : "") by Scribe \(appVersion).",
            "\(plural(counts.notes, "note", "notes")), \(plural(counts.attachments, "attachment", "attachments")), "
                + "\(plural(counts.sessions, "transcript", "transcripts")), \(plural(counts.tasks, "task", "tasks")).",
        ]
        if counts.settings > 0 {
            lines.append("\(plural(counts.settings, "setting", "settings")) will be restored.")
        }
        return lines.joined(separator: "\n")
    }
}
