// Scribe/Storage/SemanticEmbeddingStore.swift
import Foundation
import GRDB

// MARK: - Schema

/// The `embeddings` table behind on-device semantic search (see
/// `Scribe/Intelligence/Semantic`). One row per text chunk of a note or a
/// transcript, holding the chunk's embedding vector as packed Float32.
///
/// Foundation + GRDB only: Storage/ is compiled into the iOS target too, which
/// runs the same migrations (it never builds the index itself).
enum SemanticEmbeddingSchema {

    /// Migration name. Registered by `DatabaseManager.makeMigrator()`.
    static let migrationName = "v23_embeddings"
    static let tableName = "embeddings"

    /// Registers the additive `v23_embeddings` migration.
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationName) { db in
            try db.create(table: tableName) { t in
                // "<sourceType>:<sourceId>:<chunkIndex>"
                t.column("id", .text).primaryKey()
                // "note" or "session"
                t.column("sourceType", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("chunkIndex", .integer).notNull()
                // Stable hash of the chunk text: unchanged chunks keep their vector.
                t.column("textHash", .text).notNull()
                // Change stamp of the whole source when it was indexed
                // (note updatedAt / transcript shape); equal stamp = skip.
                t.column("sourceStamp", .text).notNull()
                // Which embedder produced the vector; vectors of different
                // embedders are never compared.
                t.column("embedder", .text).notNull()
                t.column("dimension", .integer).notNull()
                // Packed little-endian Float32, `dimension` values, L2-normalized.
                t.column("vector", .blob).notNull()
                // The chunk text, shown as evidence in Ask / search.
                t.column("text", .text).notNull()
                // Session-relative start of a transcript chunk (nil for notes).
                t.column("startMs", .integer)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "embeddings_source_idx",
                          on: tableName,
                          columns: ["sourceType", "sourceId"])
            try db.create(index: "embeddings_embedder_idx",
                          on: tableName,
                          columns: ["embedder"])
        }
    }
}

// MARK: - Vector codec

/// Packs `[Float]` vectors into BLOBs (little-endian Float32) and back.
enum SemanticVectorCodec {

    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decodes a BLOB written by ``encode(_:)``. Returns nil when the byte
    /// count isn't a whole number of Float32 values.
    static func decode(_ data: Data) -> [Float]? {
        let size = MemoryLayout<UInt32>.size
        guard data.count % size == 0 else { return nil }
        let count = data.count / size
        var out = [Float]()
        out.reserveCapacity(count)
        let bytes = [UInt8](data)
        var offset = 0
        for _ in 0..<count {
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            out.append(Float(bitPattern: bits))
            offset += size
        }
        return out
    }
}

// MARK: - Records

/// Kinds of content the semantic index covers.
enum SemanticSourceType: String, Sendable, CaseIterable {
    case note
    case session
}

/// One chunk ready to be written (vector already computed).
struct SemanticChunkInput: Equatable, Sendable {
    var chunkIndex: Int
    var text: String
    var textHash: String
    var vector: [Float]
    var startMs: Int?
}

/// One stored chunk, as read back for search.
struct SemanticStoredChunk: Equatable, Sendable {
    var id: String
    var sourceType: SemanticSourceType
    var sourceId: String
    var chunkIndex: Int
    var text: String
    var startMs: Int?
    var vector: [Float]
}

// MARK: - Store

/// Reads and writes the `embeddings` table. Thread-safe (GRDB's queue
/// serializes access); holds no mutable state.
final class SemanticEmbeddingStore: @unchecked Sendable {

    let dbManager: DatabaseManager

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    nonisolated static func chunkId(sourceType: SemanticSourceType, sourceId: String, chunkIndex: Int) -> String {
        "\(sourceType.rawValue):\(sourceId):\(chunkIndex)"
    }

    /// `sourceId → sourceStamp` for every indexed source of `sourceType`
    /// produced by `embedder`.
    func stamps(sourceType: SemanticSourceType, embedder: String) throws -> [String: String] {
        try dbManager.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sourceId, MIN(sourceStamp) AS stamp FROM embeddings
                WHERE sourceType = ? AND embedder = ?
                GROUP BY sourceId
                """, arguments: [sourceType.rawValue, embedder])
            var out: [String: String] = [:]
            for row in rows {
                let id: String = row["sourceId"]
                let stamp: String = row["stamp"]
                out[id] = stamp
            }
            return out
        }
    }

    /// `textHash → vector` of a source's current chunks for `embedder`, so
    /// re-indexing only embeds chunks whose text changed.
    func existingVectors(sourceType: SemanticSourceType, sourceId: String, embedder: String) throws -> [String: [Float]] {
        try dbManager.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT textHash, vector FROM embeddings
                WHERE sourceType = ? AND sourceId = ? AND embedder = ?
                """, arguments: [sourceType.rawValue, sourceId, embedder])
            var out: [String: [Float]] = [:]
            for row in rows {
                let hash: String = row["textHash"]
                let blob: Data = row["vector"]
                if let vector = SemanticVectorCodec.decode(blob) { out[hash] = vector }
            }
            return out
        }
    }

    /// Atomically replaces every chunk of one source.
    func replaceChunks(sourceType: SemanticSourceType,
                       sourceId: String,
                       stamp: String,
                       embedder: String,
                       chunks: [SemanticChunkInput],
                       now: Date = Date()) throws {
        try dbManager.database.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE sourceType = ? AND sourceId = ?",
                           arguments: [sourceType.rawValue, sourceId])
            for chunk in chunks {
                try db.execute(sql: """
                    INSERT INTO embeddings
                        (id, sourceType, sourceId, chunkIndex, textHash, sourceStamp,
                         embedder, dimension, vector, text, startMs, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        Self.chunkId(sourceType: sourceType, sourceId: sourceId, chunkIndex: chunk.chunkIndex),
                        sourceType.rawValue, sourceId, chunk.chunkIndex, chunk.textHash, stamp,
                        embedder, chunk.vector.count, SemanticVectorCodec.encode(chunk.vector),
                        chunk.text, chunk.startMs, now
                    ])
            }
        }
    }

    /// Removes every chunk of `sourceType` whose source id is not in
    /// `liveIds` (deleted notes / sessions). Returns the number of rows removed.
    @discardableResult
    func removeSources(sourceType: SemanticSourceType, notIn liveIds: Set<String>) throws -> Int {
        try dbManager.database.write { db in
            let indexed = try String.fetchAll(db, sql: """
                SELECT DISTINCT sourceId FROM embeddings WHERE sourceType = ?
                """, arguments: [sourceType.rawValue])
            var removed = 0
            for id in indexed where !liveIds.contains(id) {
                try db.execute(sql: "DELETE FROM embeddings WHERE sourceType = ? AND sourceId = ?",
                               arguments: [sourceType.rawValue, id])
                removed += db.changesCount
            }
            return removed
        }
    }

    /// Drops rows produced by any embedder other than `embedder`.
    @discardableResult
    func removeOtherEmbedders(keeping embedder: String) throws -> Int {
        try dbManager.database.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE embedder <> ?", arguments: [embedder])
            return db.changesCount
        }
    }

    /// Every chunk produced by `embedder`, for the in-memory search matrix.
    func allChunks(embedder: String) throws -> [SemanticStoredChunk] {
        try dbManager.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, sourceType, sourceId, chunkIndex, text, startMs, vector
                FROM embeddings WHERE embedder = ?
                ORDER BY sourceType, sourceId, chunkIndex
                """, arguments: [embedder])
            return rows.compactMap { row -> SemanticStoredChunk? in
                let rawType: String = row["sourceType"]
                let blob: Data = row["vector"]
                guard let type = SemanticSourceType(rawValue: rawType),
                      let vector = SemanticVectorCodec.decode(blob) else { return nil }
                return SemanticStoredChunk(
                    id: row["id"],
                    sourceType: type,
                    sourceId: row["sourceId"],
                    chunkIndex: row["chunkIndex"],
                    text: row["text"],
                    startMs: row["startMs"],
                    vector: vector
                )
            }
        }
    }

    func chunkCount() throws -> Int {
        try dbManager.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
        }
    }

    func deleteAll() throws {
        try dbManager.database.write { db in
            try db.execute(sql: "DELETE FROM embeddings")
        }
    }
}
