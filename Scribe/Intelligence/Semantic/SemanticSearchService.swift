// Scribe/Intelligence/Semantic/SemanticSearchService.swift
import Foundation

/// The "Semantic search (on-device)" setting.
enum SemanticSearchSettings {
    /// UserDefaults key of the toggle (Settings → Intelligence). Off by
    /// default: building the index costs some background CPU.
    static let enabledKey = "semanticSearchEnabled"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The provider retrieval should consult right now: the shared index
    /// when the setting is on, otherwise nil (pure full-text search).
    nonisolated static func activeProvider(defaults: UserDefaults = .standard) -> (any SemanticCandidateProviding)? {
        guard isEnabled(defaults: defaults) else { return nil }
        return SemanticSearchService.shared
    }
}

/// One semantic match: a stored chunk and its similarity to the query.
struct SemanticHit: Equatable, Sendable {
    var chunkId: String
    var sourceType: SemanticSourceType
    var sourceId: String
    var text: String
    var startMs: Int?
    var score: Float
}

/// Anything that can answer "which stored chunks are closest to this text".
/// `MeetingRetriever` and universal search depend on this, so tests can
/// inject a fake.
protocol SemanticCandidateProviding: Sendable {
    func semanticHits(for query: String, limit: Int, sourceTypes: Set<SemanticSourceType>?) -> [SemanticHit]
}

/// Query side of the semantic index: keeps every stored vector in one
/// row-major Float32 matrix in memory (reloaded after the indexer writes)
/// and answers top-k cosine queries with a single `vDSP_mmul`.
///
/// Synchronous and lock-protected so the (synchronous) Ask retriever can
/// call it from its background task.
final class SemanticSearchService: SemanticCandidateProviding, @unchecked Sendable {

    static let shared = SemanticSearchService(
        store: SemanticEmbeddingStore(dbManager: .shared),
        embedder: NLSemanticEmbedder.shared
    )

    private let store: SemanticEmbeddingStore
    private let embedder: any SemanticTextEmbedding

    private let lock = NSLock()
    private var matrix: Matrix?
    private var isDirty = true

    /// The loaded index: chunk metadata plus the packed vectors.
    private struct Matrix {
        var embedder: String
        var dimension: Int
        var chunks: [SemanticStoredChunk]
        var values: [Float]
    }

    init(store: SemanticEmbeddingStore, embedder: any SemanticTextEmbedding) {
        self.store = store
        self.embedder = embedder
    }

    /// Marks the in-memory matrix stale; the next query reloads it.
    func invalidate() {
        lock.lock()
        isDirty = true
        lock.unlock()
    }

    /// Releases the matrix (e.g. when the feature is switched off).
    func purgeCache() {
        lock.lock()
        matrix = nil
        isDirty = true
        lock.unlock()
    }

    func semanticHits(for query: String, limit: Int, sourceTypes: Set<SemanticSourceType>? = nil) -> [SemanticHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty,
              let embedderId = embedder.identifier,
              let queryVector = embedder.embed(trimmed) else { return [] }

        lock.lock()
        defer { lock.unlock() }
        guard let matrix = loadedMatrix(embedder: embedderId), matrix.dimension == queryVector.count else { return [] }

        let scores = SemanticVectorMath.scores(query: queryVector, matrix: matrix.values,
                                               rows: matrix.chunks.count, dimension: matrix.dimension)
        // Over-fetch when filtering by type, then trim.
        let fetch = sourceTypes == nil ? limit : min(matrix.chunks.count, limit * 4)
        var hits: [SemanticHit] = []
        for scored in SemanticVectorMath.topK(scores: scores, k: fetch) {
            let chunk = matrix.chunks[scored.index]
            if let sourceTypes, !sourceTypes.contains(chunk.sourceType) { continue }
            hits.append(SemanticHit(chunkId: chunk.id, sourceType: chunk.sourceType, sourceId: chunk.sourceId,
                                    text: chunk.text, startMs: chunk.startMs, score: scored.score))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Current matrix for `embedder`, reloading from the database when stale.
    /// Call with the lock held.
    private func loadedMatrix(embedder embedderId: String) -> Matrix? {
        if !isDirty, let matrix, matrix.embedder == embedderId { return matrix }
        do {
            let chunks = try store.allChunks(embedder: embedderId)
            let dimension = chunks.first?.vector.count ?? 0
            let usable = chunks.filter { $0.vector.count == dimension }
            var values: [Float] = []
            values.reserveCapacity(usable.count * dimension)
            for chunk in usable { values += chunk.vector }
            // The vectors are kept in `values`; drop the per-chunk copies.
            let slim = usable.map { chunk -> SemanticStoredChunk in
                var copy = chunk
                copy.vector = []
                return copy
            }
            let loaded = Matrix(embedder: embedderId, dimension: dimension, chunks: slim, values: values)
            matrix = loaded
            isDirty = false
            return loaded
        } catch {
            Log.intelligence.error("Semantic index load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
