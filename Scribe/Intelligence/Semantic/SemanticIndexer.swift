// Scribe/Intelligence/Semantic/SemanticIndexer.swift
import Foundation
import GRDB

/// Builds the semantic index incrementally.
///
/// Each pass compares every note's / finished session's change stamp with
/// the stamp stored on its chunks, re-chunks only the sources that changed,
/// re-embeds only chunks whose text hash is new, and drops chunks of sources
/// that no longer exist. A pass stops after `maxEmbeddings` model calls so
/// the background loop can yield between batches (see
/// ``SemanticIndexScheduler``).
///
/// Note bodies are read from `notes_fts` (which mirrors the on-disk body),
/// so indexing never touches the vault files.
final class SemanticIndexer: @unchecked Sendable {

    struct PassResult: Equatable, Sendable {
        /// Model calls made.
        var embedded = 0
        /// Sources whose chunks were rewritten.
        var updatedSources = 0
        /// Rows removed for deleted sources / an old embedder.
        var removedRows = 0
        /// False when the pass stopped early (budget or `shouldContinue`).
        var isComplete = true
        /// True when the index changed, so search caches must reload.
        var changedIndex: Bool { updatedSources > 0 || removedRows > 0 }
    }

    let dbManager: DatabaseManager
    let store: SemanticEmbeddingStore
    let embedder: any SemanticTextEmbedding

    init(dbManager: DatabaseManager, store: SemanticEmbeddingStore, embedder: any SemanticTextEmbedding) {
        self.dbManager = dbManager
        self.store = store
        self.embedder = embedder
    }

    /// Runs one indexing pass. `shouldContinue` is polled between sources
    /// (return false to stop early, e.g. on task cancellation).
    func runPass(maxEmbeddings: Int, shouldContinue: () -> Bool = { true }) throws -> PassResult {
        var result = PassResult()
        guard let embedderId = embedder.identifier else {
            result.isComplete = true
            return result
        }
        result.removedRows += try store.removeOtherEmbedders(keeping: embedderId)

        let fullBudget = max(maxEmbeddings, 1)
        var budget = fullBudget

        // Notes
        let notes = try noteStamps()
        result.removedRows += try store.removeSources(sourceType: .note, notIn: Set(notes.keys))
        let noteIndexed = try store.stamps(sourceType: .note, embedder: embedderId)
        for (noteId, stamp) in notes.sorted(by: { $0.key < $1.key }) where noteIndexed[noteId] != stamp {
            guard shouldContinue(), budget > 0 else { result.isComplete = false; return result }
            guard let content = try noteContent(id: noteId) else { continue }
            let chunks = SemanticChunker.chunkNote(body: content.body).map { (text: $0, startMs: Int?.none) }
            // An empty note with nothing indexed has nothing to write.
            if chunks.isEmpty && noteIndexed[noteId] == nil { continue }
            let used = try write(sourceType: .note, sourceId: noteId, stamp: stamp,
                                 title: content.title, chunks: chunks, embedderId: embedderId, budget: budget, fullBudget: fullBudget)
            guard let used else { result.isComplete = false; return result }
            budget -= used
            result.embedded += used
            result.updatedSources += 1
        }

        // Finished sessions
        let sessions = try sessionStamps()
        result.removedRows += try store.removeSources(sourceType: .session, notIn: Set(sessions.keys))
        let sessionIndexed = try store.stamps(sourceType: .session, embedder: embedderId)
        for (sessionId, info) in sessions.sorted(by: { $0.key < $1.key }) where sessionIndexed[sessionId] != info.stamp {
            guard shouldContinue(), budget > 0 else { result.isComplete = false; return result }
            let lines = try transcriptLines(sessionId: sessionId)
            let chunks = SemanticChunker.chunkTranscript(lines).map { (text: $0.text, startMs: Optional($0.startMs)) }
            if chunks.isEmpty && sessionIndexed[sessionId] == nil { continue }
            let used = try write(sourceType: .session, sourceId: sessionId, stamp: info.stamp,
                                 title: info.title, chunks: chunks, embedderId: embedderId, budget: budget, fullBudget: fullBudget)
            guard let used else { result.isComplete = false; return result }
            budget -= used
            result.embedded += used
            result.updatedSources += 1
        }
        return result
    }

    // MARK: - Writing

    /// Embeds what's new and replaces the source's rows. Returns the number
    /// of model calls, or nil when the source needs more than the `budget`
    /// left in this pass (it is left for the next pass, untouched).
    private func write(sourceType: SemanticSourceType,
                       sourceId: String,
                       stamp: String,
                       title: String,
                       chunks: [(text: String, startMs: Int?)],
                       embedderId: String,
                       budget: Int,
                       fullBudget: Int) throws -> Int? {
        let existing = try store.existingVectors(sourceType: sourceType, sourceId: sourceId, embedder: embedderId)
        let titleLine = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hash covers the title too: it is part of the embedded input.
        let hashed = chunks.map { chunk -> (text: String, startMs: Int?, hash: String, input: String) in
            let input = titleLine.isEmpty ? chunk.text : "\(titleLine)\n\(chunk.text)"
            return (chunk.text, chunk.startMs, SemanticChunker.stableHash(input), input)
        }
        let missing = hashed.filter { existing[$0.hash] == nil }.count
        // A source that doesn't fit what's left of this pass waits for the
        // next one. One bigger than a whole batch is still indexed in one go
        // when the pass has its full budget, so it can't be starved forever.
        if missing > budget && budget < fullBudget {
            return nil
        }

        var used = 0
        var inputs: [SemanticChunkInput] = []
        for (index, chunk) in hashed.enumerated() {
            let vector: [Float]
            if let cached = existing[chunk.hash] {
                vector = cached
            } else {
                used += 1
                guard let embedded = embedder.embed(chunk.input) else { continue }
                vector = embedded
            }
            inputs.append(SemanticChunkInput(chunkIndex: index, text: chunk.text, textHash: chunk.hash,
                                              vector: vector, startMs: chunk.startMs))
        }
        try store.replaceChunks(sourceType: sourceType, sourceId: sourceId, stamp: stamp,
                                embedder: embedderId, chunks: inputs)
        return used
    }

    // MARK: - Sources

    /// `noteId → stamp` (the note's `updatedAt`).
    private func noteStamps() throws -> [String: String] {
        try dbManager.database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, updatedAt FROM notes")
            var out: [String: String] = [:]
            for row in rows {
                let id: String = row["id"]
                let updated: Date? = row["updatedAt"]
                out[id] = Self.stamp(updated)
            }
            return out
        }
    }

    private func noteContent(id: String) throws -> (title: String, body: String)? {
        try dbManager.database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT n.title AS title, f.body AS body
                FROM notes n LEFT JOIN notes_fts f ON f.noteId = n.id
                WHERE n.id = ? LIMIT 1
                """, arguments: [id]) else { return nil }
            let title: String = (row["title"] as String?) ?? ""
            let body: String = (row["body"] as String?) ?? ""
            return (title, body)
        }
    }

    /// `sessionId → (stamp, title)` for sessions that finished recording.
    /// The stamp tracks the transcript's shape (count, last id, total length,
    /// reassignments), which changes on edits, diarization and moves.
    private func sessionStamps() throws -> [String: (stamp: String, title: String)] {
        try dbManager.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id AS id, s.title AS title,
                       COUNT(seg.id) AS n, COALESCE(MAX(seg.id), 0) AS maxId,
                       COALESCE(SUM(LENGTH(seg.text)), 0) AS len,
                       COALESCE(SUM(CASE WHEN seg.speakerOverride IS NULL THEN 0 ELSE 1 END), 0) AS overrides
                FROM sessions s
                LEFT JOIN segments seg ON seg.sessionId = s.id
                WHERE s.endedAt IS NOT NULL
                GROUP BY s.id
                """)
            var out: [String: (stamp: String, title: String)] = [:]
            for row in rows {
                let id: String = row["id"]
                let title: String = (row["title"] as String?) ?? ""
                let count: Int = row["n"]
                let maxId: Int64 = row["maxId"]
                let length: Int = row["len"]
                let overrides: Int = row["overrides"]
                let titleHash = SemanticChunker.stableHash(title)
                out[id] = ("c\(count)-m\(maxId)-l\(length)-o\(overrides)-t\(titleHash)", title)
            }
            return out
        }
    }

    private func transcriptLines(sessionId: String) throws -> [SemanticChunker.TranscriptLine] {
        try dbManager.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT speaker, speakerOverride, text, startMs FROM segments
                WHERE sessionId = ? ORDER BY startMs ASC, id ASC
                """, arguments: [sessionId])
            return rows.map { row in
                let speaker: String = (row["speakerOverride"] as String?) ?? ((row["speaker"] as String?) ?? "")
                return SemanticChunker.TranscriptLine(
                    speaker: SpeakerNameResolver.canonicalKey(speaker) == SpeakerNameResolver.remoteKey ? "Remote" : speaker,
                    text: (row["text"] as String?) ?? "",
                    startMs: (row["startMs"] as Int?) ?? 0
                )
            }
        }
    }

    nonisolated static func stamp(_ date: Date?) -> String {
        guard let date else { return "0" }
        return String(format: "%.3f", date.timeIntervalSinceReferenceDate)
    }
}
