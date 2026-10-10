import XCTest
import GRDB
@testable import Scribe

/// Deterministic stand-in for the NaturalLanguage embedder: a hashed
/// bag-of-words vector, so texts sharing words are close.
final class BagOfWordsTestEmbedder: SemanticTextEmbedding, @unchecked Sendable {
    let dimension = 64
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var identifier: String? { "test-bow:64" }

    func embed(_ text: String) -> [Float]? {
        lock.lock(); _calls += 1; lock.unlock()
        var vector = [Float](repeating: 0, count: dimension)
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty else { return nil }
        for word in words {
            let hash = SemanticChunker.stableHash(String(word))
            let bucket = Int(UInt64(hash, radix: 16)! % UInt64(dimension))
            vector[bucket] += 1
        }
        return SemanticVectorMath.normalized(vector)
    }
}

/// Fixed hits, for retrieval tests.
struct StubSemanticProvider: SemanticCandidateProviding {
    let hits: [SemanticHit]
    func semanticHits(for query: String, limit: Int, sourceTypes: Set<SemanticSourceType>?) -> [SemanticHit] {
        Array(hits.prefix(limit))
    }
}

final class SemanticChunkerTests: XCTestCase {

    func testShortNoteIsOneChunkWithoutMarkup() {
        let chunks = SemanticChunker.chunkNote(body: "# Plan\n\n- Ship the beta\n- Write docs\n\nSome **prose** here.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Plan"))
        XCTAssertTrue(chunks[0].contains("Ship the beta"))
        XCTAssertFalse(chunks[0].contains("# "))
        XCTAssertFalse(chunks[0].contains("- Ship"))
    }

    func testFrontMatterAndFenceMarkersAreDropped() {
        let body = "---\ntags: [a]\nid: 123\n---\nHello world\n\n```\nlet x = 1\n```\n"
        let chunks = SemanticChunker.chunkNote(body: body)
        // Front matter is gone; fence markers are dropped, the code is kept.
        XCTAssertEqual(chunks, ["Hello world\n\nlet x = 1"])
    }

    func testLongTextIsSplitWithinLimit() {
        let sentence = "This sentence talks about the quarterly roadmap and hiring. "
        let body = String(repeating: sentence, count: 60)
        let chunks = SemanticChunker.chunkNote(body: body, maxChars: 300)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 300)
            XCTAssertFalse(chunk.isEmpty)
        }
    }

    func testHugeWordIsHardSplit() {
        let chunks = SemanticChunker.chunkNote(body: String(repeating: "x", count: 250), maxChars: 100)
        XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
    }

    func testTranscriptChunksGroupLinesAndKeepStart() {
        let lines = (0..<10).map {
            SemanticChunker.TranscriptLine(speaker: "Alice", text: "Line number \($0) about the launch.", startMs: $0 * 1_000)
        }
        let chunks = SemanticChunker.chunkTranscript(lines, maxChars: 120)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startMs, 0)
        XCTAssertTrue(chunks[0].text.hasPrefix("Alice: Line number 0"))
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.text.count, 120) }
        // Start times increase.
        XCTAssertEqual(chunks.map(\.startMs), chunks.map(\.startMs).sorted())
    }

    func testTranscriptSkipsEmptyLines() {
        let lines = [
            SemanticChunker.TranscriptLine(speaker: "you", text: "   ", startMs: 0),
            SemanticChunker.TranscriptLine(speaker: "", text: "Hello", startMs: 500)
        ]
        XCTAssertEqual(SemanticChunker.chunkTranscript(lines), [.init(text: "Hello", startMs: 500)])
    }

    func testStableHashIsDeterministicAndDistinct() {
        XCTAssertEqual(SemanticChunker.stableHash("hello"), SemanticChunker.stableHash("hello"))
        XCTAssertNotEqual(SemanticChunker.stableHash("hello"), SemanticChunker.stableHash("hello!"))
        XCTAssertEqual(SemanticChunker.stableHash("").count, 16)
        // FNV-1a 64 of "a".
        XCTAssertEqual(SemanticChunker.stableHash("a"), "af63dc4c8601ec8c")
    }
}

final class SemanticVectorMathTests: XCTestCase {

    func testCosine() {
        XCTAssertEqual(SemanticVectorMath.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(SemanticVectorMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(SemanticVectorMath.cosine([1, 1], [-1, -1]), -1, accuracy: 1e-6)
        XCTAssertEqual(SemanticVectorMath.cosine([1, 2, 3], [2, 4, 6]), 1, accuracy: 1e-6)
        XCTAssertEqual(SemanticVectorMath.cosine([0, 0], [1, 1]), 0)
        XCTAssertEqual(SemanticVectorMath.cosine([1], [1, 2]), 0)
    }

    func testNormalize() {
        let v = SemanticVectorMath.normalized([3, 4])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(SemanticVectorMath.norm(v), 1, accuracy: 1e-6)
        XCTAssertEqual(SemanticVectorMath.normalized([0, 0]), [0, 0])
    }

    func testScoresAndTopK() {
        // Three unit rows of dimension 2.
        let matrix: [Float] = [1, 0, 0, 1, 0.6, 0.8]
        let query = SemanticVectorMath.normalized([1, 1])
        let scores = SemanticVectorMath.scores(query: query, matrix: matrix, rows: 3, dimension: 2)
        XCTAssertEqual(scores.count, 3)
        XCTAssertEqual(scores[0], scores[1], accuracy: 1e-6)
        let top = SemanticVectorMath.topK(query: query, matrix: matrix, rows: 3, dimension: 2, k: 2)
        XCTAssertEqual(top.map(\.index), [2, 0])  // 0.99 first, then the lower index of the tie
        XCTAssertTrue(SemanticVectorMath.topK(query: query, matrix: matrix, rows: 3, dimension: 2, k: 0).isEmpty)
        XCTAssertTrue(SemanticVectorMath.scores(query: [1], matrix: matrix, rows: 3, dimension: 2).isEmpty)
    }

    func testTopKRespectsMinimumScore() {
        let top = SemanticVectorMath.topK(scores: [0.1, 0.9, 0.5], k: 5, minimumScore: 0.4)
        XCTAssertEqual(top.map(\.index), [1, 2])
    }

    func testVectorCodecRoundTrips() {
        let vector: [Float] = [0, 1.5, -2.25, .pi, 1e-7]
        let data = SemanticVectorCodec.encode(vector)
        XCTAssertEqual(data.count, vector.count * 4)
        XCTAssertEqual(SemanticVectorCodec.decode(data), vector)
        XCTAssertNil(SemanticVectorCodec.decode(Data([1, 2, 3])))
    }
}

final class HybridRankingTests: XCTestCase {

    func testReciprocalRankFusionSumsRanks() {
        let fused = ReciprocalRankFusion.fuse([["a", "b", "c"], ["c", "a", "d"]], k: 60)
        XCTAssertEqual(fused.first?.id, "a")  // 1/61 + 1/62
        XCTAssertEqual(fused.map(\.id).sorted(), ["a", "b", "c", "d"])
        let a = fused.first { $0.id == "a" }!.score
        XCTAssertEqual(a, 1.0 / 61 + 1.0 / 62, accuracy: 1e-12)
        let d = fused.first { $0.id == "d" }!.score
        XCTAssertEqual(d, 1.0 / 63, accuracy: 1e-12)
    }

    func testFusionWeightsAndDuplicates() {
        let fused = ReciprocalRankFusion.fuse([["x", "x", "y"], ["y"]], weights: [1, 0.5], k: 1)
        // x: 1/2; y: 1/3 + 0.5/2 = 0.583
        XCTAssertEqual(fused.map(\.id), ["y", "x"])
    }

    func testFusionTiesBreakByFirstAppearance() {
        let fused = ReciprocalRankFusion.fuse([["a"], ["b"]])
        XCTAssertEqual(fused.map(\.id), ["a", "b"])
    }

    private func snippet(_ id: String, _ kind: RetrievedSnippet.Kind = .transcript, text: String) -> RetrievedSnippet {
        RetrievedSnippet(id: id, kind: kind, sessionId: kind == .note ? nil : "s-\(id)", noteId: "n-\(id)",
                         noteTitle: "T \(id)", date: Date(), text: text)
    }

    func testHybridFusePrefersItemsInBothLists() {
        let lexical = [snippet("a", text: "alpha"), snippet("b", text: "beta")]
        let semantic = [snippet("c", text: "gamma"), snippet("b", text: "beta semantic")]
        let fused = HybridRetrieval.fuse(lexical: lexical, semantic: semantic)
        XCTAssertEqual(fused.first?.id, "b")
        XCTAssertEqual(fused.first?.text, "beta")  // lexical copy kept
        XCTAssertEqual(Set(fused.map(\.id)), ["a", "b", "c"])
        XCTAssertGreaterThan(fused.first?.score ?? 0, 0)
    }

    func testHybridAssembleKeepsScopeAndBudget() {
        let lexical = [snippet("a", text: "launch plan")]
        let semantic = [snippet("b", text: "go-to-market timeline")]
        let filter = AskScopeFilter(noteIds: ["n-b"])
        let result = HybridRetrieval.assemble(lexical: lexical, semantic: semantic, terms: ["launch"],
                                              filter: filter, budget: 10_000)
        XCTAssertEqual(result.snippets.map(\.id), ["b"])
        XCTAssertTrue(result.context.contains("go-to-market"))
        XCTAssertLessThanOrEqual(result.context.count, 10_000)
    }
}

final class EmbeddingStoreTests: XCTestCase {

    private var dbm: DatabaseManager!
    private var store: SemanticEmbeddingStore!

    override func setUp() {
        super.setUp()
        dbm = try! DatabaseManager(path: ":memory:")
        store = SemanticEmbeddingStore(dbManager: dbm)
    }

    override func tearDown() {
        store = nil
        dbm = nil
        super.tearDown()
    }

    func testMigrationIsRegistered() throws {
        try dbm.database.read { db in
            let applied = try DatabaseManager.makeMigrator().appliedMigrations(db)
            XCTAssertTrue(applied.contains("v23_embeddings"))
            XCTAssertTrue(try db.tableExists("embeddings"))
        }
    }

    func testReplaceStampsAndRemove() throws {
        let chunks = [
            SemanticChunkInput(chunkIndex: 0, text: "one", textHash: "h1", vector: [1, 0], startMs: nil),
            SemanticChunkInput(chunkIndex: 1, text: "two", textHash: "h2", vector: [0, 1], startMs: 5)
        ]
        try store.replaceChunks(sourceType: .note, sourceId: "n1", stamp: "s1", embedder: "e", chunks: chunks)
        try store.replaceChunks(sourceType: .session, sourceId: "x1", stamp: "s9", embedder: "e", chunks: [chunks[0]])

        XCTAssertEqual(try store.stamps(sourceType: .note, embedder: "e"), ["n1": "s1"])
        XCTAssertEqual(try store.existingVectors(sourceType: .note, sourceId: "n1", embedder: "e"),
                       ["h1": [1, 0], "h2": [0, 1]])
        XCTAssertEqual(try store.chunkCount(), 3)

        let all = try store.allChunks(embedder: "e")
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first { $0.id == "note:n1:1" }?.startMs, 5)

        // Replacing rewrites all of a source's rows.
        try store.replaceChunks(sourceType: .note, sourceId: "n1", stamp: "s2", embedder: "e", chunks: [chunks[1]])
        XCTAssertEqual(try store.stamps(sourceType: .note, embedder: "e"), ["n1": "s2"])
        XCTAssertEqual(try store.chunkCount(), 2)

        XCTAssertEqual(try store.removeSources(sourceType: .note, notIn: []), 1)
        XCTAssertEqual(try store.removeOtherEmbedders(keeping: "other"), 1)
        XCTAssertEqual(try store.chunkCount(), 0)
    }
}

final class SemanticIndexerTests: XCTestCase {

    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!
    private var embedder: BagOfWordsTestEmbedder!
    private var store: SemanticEmbeddingStore!
    private var indexer: SemanticIndexer!

    override func setUp() {
        super.setUp()
        dbm = try! DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
        embedder = BagOfWordsTestEmbedder()
        store = SemanticEmbeddingStore(dbManager: dbm)
        indexer = SemanticIndexer(dbManager: dbm, store: store, embedder: embedder)
    }

    override func tearDown() {
        indexer = nil
        store = nil
        embedder = nil
        transcripts = nil
        notes = nil
        dbm = nil
        super.tearDown()
    }

    @discardableResult
    private func finishedMeeting(title: String, lines: [String]) throws -> Session {
        let note = try notes.createNote(title: title, body: "")
        let session = Session(title: title, createdAt: Date(), endedAt: Date(), durationSeconds: 60, noteId: note.id)
        try dbm.database.write { try session.insert($0) }
        for (i, line) in lines.enumerated() {
            try transcripts.addSegment(sessionId: session.id, startMs: i * 1_000, endMs: (i + 1) * 1_000,
                                       speaker: "remote", text: line)
        }
        return session
    }

    func testIndexesNotesAndFinishedSessionsIncrementally() throws {
        let note = try notes.createNote(title: "Budget", body: "Marketing budget for the third quarter.")
        try finishedMeeting(title: "Hiking", lines: ["We plan a hiking trip.", "Mountains in July."])
        // A session still recording is skipped.
        let live = try notes.createNote(title: "Live", body: "")
        try transcripts.createSession(title: "Now", noteId: live.id)

        let first = try indexer.runPass(maxEmbeddings: 100)
        XCTAssertTrue(first.isComplete)
        XCTAssertGreaterThanOrEqual(first.updatedSources, 2)
        let afterFirst = embedder.calls
        XCTAssertGreaterThan(afterFirst, 0)
        let sessionStamps = try store.stamps(sourceType: .session, embedder: "test-bow:64")
        XCTAssertEqual(sessionStamps.count, 1)

        // Nothing changed: no new model calls.
        let second = try indexer.runPass(maxEmbeddings: 100)
        XCTAssertEqual(second.embedded, 0)
        XCTAssertEqual(embedder.calls, afterFirst)

        // Edit the note: it is re-embedded.
        try dbm.database.write { db in
            try db.execute(sql: "UPDATE notes SET updatedAt = ? WHERE id = ?",
                           arguments: [Date().addingTimeInterval(60), note.id])
            try NoteStore.upsertFTS(db, noteId: note.id, title: "Budget", body: "Marketing budget, revised.")
        }
        let third = try indexer.runPass(maxEmbeddings: 100)
        XCTAssertEqual(third.updatedSources, 1)
        XCTAssertGreaterThan(third.embedded, 0)
        let texts = try store.allChunks(embedder: "test-bow:64").filter { $0.sourceId == note.id }.map(\.text)
        XCTAssertEqual(texts, ["Marketing budget, revised."])

        // Deleting the note removes its chunks.
        try notes.deleteNote(id: note.id)
        let fourth = try indexer.runPass(maxEmbeddings: 100)
        XCTAssertGreaterThan(fourth.removedRows, 0)
        XCTAssertTrue(try store.allChunks(embedder: "test-bow:64").allSatisfy { $0.sourceId != note.id })
    }

    func testPassStopsAtBudget() throws {
        for i in 0..<5 {
            try notes.createNote(title: "Note \(i)", body: "Body text number \(i).")
        }
        let partial = try indexer.runPass(maxEmbeddings: 2)
        XCTAssertFalse(partial.isComplete)
        XCTAssertLessThanOrEqual(partial.embedded, 2)
        var rounds = 0
        var result = partial
        while !result.isComplete && rounds < 10 {
            result = try indexer.runPass(maxEmbeddings: 2)
            rounds += 1
        }
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(try store.stamps(sourceType: .note, embedder: "test-bow:64").count, 5)
    }

    func testSearchServiceFindsClosestNote() throws {
        let budget = try notes.createNote(title: "Budget", body: "Marketing budget and spend for the quarter.")
        try notes.createNote(title: "Trip", body: "Hiking trip to the mountains with friends.")
        _ = try indexer.runPass(maxEmbeddings: 100)

        let service = SemanticSearchService(store: store, embedder: embedder)
        let hits = service.semanticHits(for: "marketing spend", limit: 1, sourceTypes: nil)
        XCTAssertEqual(hits.first?.sourceId, budget.id)
        XCTAssertEqual(hits.first?.sourceType, .note)

        XCTAssertTrue(service.semanticHits(for: "marketing", limit: 5, sourceTypes: [.session]).isEmpty)
        XCTAssertTrue(service.semanticHits(for: "   ", limit: 5, sourceTypes: nil).isEmpty)
    }
}

final class SemanticRetrievalIntegrationTests: XCTestCase {

    private var dbm: DatabaseManager!
    private var notes: NoteStore!

    override func setUp() {
        super.setUp()
        dbm = try! DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
    }

    override func tearDown() {
        notes = nil
        dbm = nil
        super.tearDown()
    }

    func testSemanticHitSurfacesWithoutKeywordMatch() throws {
        let forecast = try notes.createNote(title: "Forecast", body: "Quarterly revenue projections.")
        let hit = SemanticHit(chunkId: "note:\(forecast.id):0", sourceType: .note, sourceId: forecast.id,
                              text: "Quarterly revenue projections.", startMs: nil, score: 0.8)
        let retriever = MeetingRetriever(dbManager: dbm, semantic: StubSemanticProvider(hits: [hit]))

        let result = try retriever.retrieve(question: "earnings outlook?")
        XCTAssertEqual(result.snippets.first?.noteId, forecast.id)
        XCTAssertEqual(result.snippets.first?.kind, .note)
        XCTAssertTrue(result.context.contains("[[Forecast]]"))
    }

    func testHitsForMissingSourcesAreDropped() throws {
        let hit = SemanticHit(chunkId: "session:gone:0", sourceType: .session, sourceId: "gone",
                              text: "text", startMs: 0, score: 0.5)
        let snippets = try dbm.database.read { db in try MeetingRetriever.snippets(for: [hit], db) }
        XCTAssertTrue(snippets.isEmpty)
    }

    func testRelatedSectionSkipsListedNotesAndDuplicates() {
        let candidates = [
            SemanticRelatedSearch.Candidate(noteId: "a", title: "A", snippet: "alpha"),
            SemanticRelatedSearch.Candidate(noteId: "b", title: "", snippet: "beta  text"),
            SemanticRelatedSearch.Candidate(noteId: "b", title: "", snippet: "again"),
            SemanticRelatedSearch.Candidate(noteId: "c", title: "C", snippet: "gamma")
        ]
        let section = SemanticRelatedSearch.section(from: candidates, excludingNoteIds: ["a"], limit: 5)
        XCTAssertEqual(section?.id, "related")
        XCTAssertEqual(section?.results.map(\.id), ["related-b", "related-c"])
        XCTAssertEqual(section?.results.first?.title, "(Untitled)")
        XCTAssertEqual(section?.results.first?.snippet, "beta text")
        XCTAssertNil(SemanticRelatedSearch.section(from: [], excludingNoteIds: []))
    }

    func testListedNoteIdsReadsNotesSection() {
        let notesSection = SearchResultSection(id: "notes", title: "Notes", results: [
            SearchResult(id: "note-1", title: "One", snippet: "", destination: .note("1"), icon: "note.text")
        ])
        let other = SearchResultSection(id: "tasks", title: "Tasks", results: [
            SearchResult(id: "task-2", title: "Two", snippet: "", destination: .task("2"), icon: "checkmark.circle")
        ])
        XCTAssertEqual(SemanticRelatedSearch.listedNoteIds(in: [notesSection, other]), ["1"])
    }
}
