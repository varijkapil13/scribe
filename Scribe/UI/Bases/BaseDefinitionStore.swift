import Foundation

/// File-backed CRUD store for ``BaseDefinition``s.
///
/// ## Why JSON files in the vault (not a GRDB table)
///
/// Scribe's vault is the source of truth: notes live as `.md` files under
/// `NotesDirectory.root` and the GRDB database (`DatabaseManager`) is only an
/// *index* rebuilt from those files (see `NoteIndexReconciler`). Storing base
/// definitions the same way — one JSON file per base under a `.scribe/bases/`
/// folder inside the vault root — keeps them:
///
/// * **portable**: bases travel with the vault (and sync via iCloud Drive
///   alongside the notes folder, like the rest of the vault content);
/// * **diff-friendly / hand-editable**: plain JSON, no migration;
/// * **decoupled from the schema**: no new GRDB table / migration to add,
///   which matches how every other *vault artifact* (notes, daily notes,
///   attachments) is already a file rather than a DB row.
///
/// The `.scribe/` prefix keeps these app-managed files out of the way of the
/// user's own note files (the vault walkers in `NoteFileStore` only pick up
/// `.md` files, so a `.json` here is ignored by the note index regardless).
///
/// The store is pure file I/O over an injectable directory, so it's unit
/// testable against a temp location with no database or app singletons.
final class BaseDefinitionStore: @unchecked Sendable {

    /// Root of the vault (the `Notes/` directory). Base definitions live in a
    /// `.scribe/bases/` subfolder of it.
    private let vaultRoot: URL
    private let fileManager: FileManager

    /// Production instance, rooted at the live note vault. Falls back to a
    /// temp directory if no file store is configured (logic-only contexts) so
    /// the screen still functions without crashing.
    static let shared = BaseDefinitionStore()

    /// - Parameter vaultRoot: the vault's `Notes/` root. When nil, resolves
    ///   from `NoteStore.shared`'s file store, then a temp fallback.
    init(vaultRoot: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let vaultRoot {
            self.vaultRoot = vaultRoot
        } else if let root = NoteStore.shared.fileStore?.directory.root {
            self.vaultRoot = root
        } else {
            self.vaultRoot = fileManager.temporaryDirectory
                .appendingPathComponent("ScribeBases", isDirectory: true)
        }
    }

    /// `<vaultRoot>/.scribe/bases/`, created on demand.
    private var basesDirectory: URL {
        vaultRoot
            .appendingPathComponent(".scribe", isDirectory: true)
            .appendingPathComponent("bases", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: basesDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        basesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - CRUD

    /// All saved base definitions, ordered by creation time (oldest first) so
    /// the picker stays stable as bases are added.
    func list() throws -> [BaseDefinition] {
        guard fileManager.fileExists(atPath: basesDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: basesDirectory,
            includingPropertiesForKeys: nil
        )
        let definitions = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> BaseDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(BaseDefinition.self, from: data)
            }
        return definitions.sorted {
            $0.createdAt == $1.createdAt
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.createdAt < $1.createdAt
        }
    }

    /// Load a single definition by id, or nil if absent / unreadable.
    func load(id: UUID) -> BaseDefinition? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(BaseDefinition.self, from: data)
    }

    /// Persist a definition (create or overwrite), bumping `updatedAt`.
    /// Returns the saved value so callers can adopt the new timestamp.
    @discardableResult
    func save(_ definition: BaseDefinition) throws -> BaseDefinition {
        try ensureDirectory()
        var toWrite = definition
        toWrite.updatedAt = Date()
        let data = try Self.encoder.encode(toWrite)
        try data.write(to: fileURL(for: toWrite.id), options: .atomic)
        return toWrite
    }

    /// Create and persist a new, empty base with the given name.
    @discardableResult
    func create(name: String) throws -> BaseDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = BaseDefinition(name: trimmed.isEmpty ? "New Base" : trimmed)
        return try save(definition)
    }

    /// Rename a base in place, persisting the change. No-op (returns nil) if
    /// the base no longer exists.
    @discardableResult
    func rename(id: UUID, to name: String) throws -> BaseDefinition? {
        guard var definition = load(id: id) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.name = trimmed.isEmpty ? definition.name : trimmed
        return try save(definition)
    }

    /// Delete a base by id. Silent no-op if the file is already gone.
    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
