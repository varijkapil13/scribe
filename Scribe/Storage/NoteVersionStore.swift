// Scribe/Storage/NoteVersionStore.swift
import Foundation
import GRDB

enum NoteVersionStoreError: Error, LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "This version couldn't be read: \(reason)"
        }
    }
}

/// Version history for notes: snapshots of a note's previous content, taken
/// before saves that change it (see `NoteVersionPolicy` for the throttle).
///
/// Content is stored LZFSE-compressed under `directory` (the app's support
/// folder — never the vault, so snapshots don't sync or show up as notes),
/// indexed by the `note_versions` table (migration `v24_note_versions`).
/// Every write path is best-effort from the caller's perspective: a snapshot
/// failure must never block saving the note itself.
///
/// `@unchecked Sendable`: the only state is immutable configuration plus the
/// thread-safe `DatabaseQueue`.
final class NoteVersionStore: @unchecked Sendable {

    let dbManager: DatabaseManager
    /// Root folder for compressed snapshot files.
    let directory: URL

    private var db: DatabaseQueue { dbManager.database }

    init(dbManager: DatabaseManager, directory: URL) {
        self.dbManager = dbManager
        self.directory = directory
    }

    /// The production store: `<Application Support>/Scribe/NoteVersions`
    /// (next to the fixture database in UI-test fixture mode).
    static func makeDefault(dbManager: DatabaseManager) -> NoteVersionStore? {
        let base: URL
        if let fixture = AppLaunchEnvironment.fixtureDatabasePath {
            base = URL(fileURLWithPath: fixture).deletingLastPathComponent()
        } else {
            guard let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            base = appSupport.appendingPathComponent("Scribe", isDirectory: true)
        }
        return NoteVersionStore(dbManager: dbManager,
                                directory: base.appendingPathComponent("NoteVersions", isDirectory: true))
    }

    // MARK: - Migration

    /// Registers `v24_note_versions`. Called from `DatabaseManager.makeMigrator`.
    static func registerNoteVersionsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v24_note_versions") { db in
            try db.create(table: "note_versions") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("noteId", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("reason", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("byteCount", .integer).notNull().defaults(to: 0)
                t.column("contentHash", .text).notNull()
                t.column("fileName", .text).notNull()
            }
            try db.create(index: "note_versions_noteId_createdAt_idx",
                          on: "note_versions",
                          columns: ["noteId", "createdAt"])
        }
    }

    // MARK: - Queries

    /// All versions of a note, newest first.
    func versions(noteId: String) throws -> [NoteVersionRecord] {
        try db.read { database in
            try NoteVersionRecord
                .filter(Column("noteId") == noteId)
                .order(Column("createdAt").desc)
                .fetchAll(database)
        }
    }

    func latestVersion(noteId: String) throws -> NoteVersionRecord? {
        try db.read { database in
            try NoteVersionRecord
                .filter(Column("noteId") == noteId)
                .order(Column("createdAt").desc)
                .fetchOne(database)
        }
    }

    /// The snapshot's markdown body.
    func loadBody(_ version: NoteVersionRecord) throws -> String {
        let url = directory.appendingPathComponent(version.fileName)
        let compressed = try Data(contentsOf: url)
        let data = try Self.decompress(compressed)
        guard let body = String(data: data, encoding: .utf8) else {
            throw NoteVersionStoreError.unreadable("not UTF-8 text")
        }
        return body
    }

    // MARK: - Snapshots

    /// Snapshots `previousBody` when `NoteVersionPolicy` says so. Returns the
    /// new version, or nil when none was needed.
    @discardableResult
    func recordSnapshotIfNeeded(
        noteId: String,
        title: String,
        previousBody: String,
        newBody: String,
        reason: NoteVersionReason,
        now: Date = Date()
    ) throws -> NoteVersionRecord? {
        let previousHash = Self.hash(previousBody)
        let latest = try latestVersion(noteId: noteId)
        guard NoteVersionPolicy.shouldSnapshot(
            previousBody: previousBody,
            newBody: newBody,
            previousHash: previousHash,
            reason: reason,
            lastSnapshotAt: latest?.createdAt,
            lastSnapshotHash: latest?.contentHash,
            now: now
        ) else { return nil }
        return try snapshot(noteId: noteId, title: title, body: previousBody, hash: previousHash, reason: reason, now: now)
    }

    /// Unconditionally stores `body` as a version (skipping only an exact
    /// duplicate of the newest one). Applies retention for the note after.
    @discardableResult
    func snapshot(
        noteId: String,
        title: String,
        body: String,
        reason: NoteVersionReason,
        now: Date = Date()
    ) throws -> NoteVersionRecord? {
        let hash = Self.hash(body)
        if let latest = try latestVersion(noteId: noteId), latest.contentHash == hash { return nil }
        return try snapshot(noteId: noteId, title: title, body: body, hash: hash, reason: reason, now: now)
    }

    private func snapshot(
        noteId: String,
        title: String,
        body: String,
        hash: String,
        reason: NoteVersionReason,
        now: Date
    ) throws -> NoteVersionRecord {
        let id = UUID().uuidString
        let folder = Self.folderName(forNoteId: noteId)
        let fileName = "\(folder)/\(id).lzfse"
        let data = Data(body.utf8)
        let compressed = try Self.compress(data)
        let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try compressed.write(to: directory.appendingPathComponent(fileName), options: .atomic)

        let record = NoteVersionRecord(
            id: id,
            noteId: noteId,
            createdAt: now,
            reason: reason.rawValue,
            title: title,
            byteCount: data.count,
            contentHash: hash,
            fileName: fileName
        )
        do {
            try db.write { database in try record.insert(database) }
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
            throw error
        }
        do {
            try applyRetention(noteId: noteId, now: now)
        } catch {
            Log.storage.error("NoteVersionStore: retention failed for \(noteId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return record
    }

    // MARK: - Retention / deletion

    /// Removes the note's versions `NoteVersionRetention` no longer keeps.
    /// Returns how many were removed.
    @discardableResult
    func applyRetention(noteId: String, now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        let all = try versions(noteId: noteId)
        let doomed = NoteVersionRetention.idsToDelete(
            all.map { NoteVersionRetention.Item(id: $0.id, createdAt: $0.createdAt) },
            now: now,
            calendar: calendar
        )
        guard !doomed.isEmpty else { return 0 }
        try remove(all.filter { doomed.contains($0.id) })
        return doomed.count
    }

    /// Deletes every version of a note.
    func deleteVersions(noteId: String) throws {
        try remove(try versions(noteId: noteId))
    }

    private func remove(_ records: [NoteVersionRecord]) throws {
        guard !records.isEmpty else { return }
        let ids = records.map(\.id)
        _ = try db.write { database in
            try NoteVersionRecord.deleteAll(database, keys: ids)
        }
        for record in records {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
        }
    }

    // MARK: - Helpers

    nonisolated static func hash(_ body: String) -> String {
        NoteFileFingerprint.hash(Data(body.utf8))
    }

    /// A file-system-safe folder name for a note id.
    nonisolated static func folderName(forNoteId noteId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var cleaned = ""
        for scalar in noteId.unicodeScalars {
            cleaned.unicodeScalars.append(allowed.contains(scalar) ? scalar : Unicode.Scalar(0x5F))
        }
        return cleaned.isEmpty ? "_" : cleaned
    }

    // Isolated so an SDK difference in the compression API is a one-place fix.
    nonisolated static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzfse) as Data
    }

    nonisolated static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzfse) as Data
    }
}
