// Scribe/Intelligence/Semantic/SemanticEmbedder.swift
import Foundation
import NaturalLanguage

/// Turns text into a fixed-length, unit-length vector. Implementations must
/// be safe to call from any thread.
protocol SemanticTextEmbedding: AnyObject, Sendable {
    /// Identifies the model + dimension. Vectors from different identifiers
    /// are never compared; nil when no model is usable on this Mac.
    var identifier: String? { get }
    /// The normalized embedding of `text`, or nil when it can't be embedded.
    func embed(_ text: String) -> [Float]?
}

/// On-device embeddings from the NaturalLanguage framework.
///
/// Prefers `NLContextualEmbedding` (a multilingual transformer; token
/// vectors are mean-pooled into one passage vector) and falls back to the
/// English `NLEmbedding.sentenceEmbedding` while the contextual model's
/// assets aren't downloaded yet (asking the system to fetch them for next
/// time). Everything runs locally.
///
/// NaturalLanguage objects aren't documented as thread-safe, so every call
/// is serialized behind one lock.
final class NLSemanticEmbedder: SemanticTextEmbedding, @unchecked Sendable {

    static let shared = NLSemanticEmbedder()

    private let lock = NSLock()
    private var didLoad = false
    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var loadedIdentifier: String?

    /// Max characters handed to the model per call (the contextual model
    /// truncates long inputs anyway; chunks are ~800 characters).
    static let maxInputCharacters = 2_000

    var identifier: String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return loadedIdentifier
    }

    func embed(_ text: String) -> [Float]? {
        let input = String(text.prefix(Self.maxInputCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let raw: [Double]?
        if let contextual {
            raw = Self.contextualVector(contextual, text: input)
        } else if let sentence {
            raw = sentence.vector(for: input)
        } else {
            raw = nil
        }
        guard let raw, !raw.isEmpty else { return nil }
        let vector = SemanticVectorMath.normalized(raw.map { Float($0) })
        return SemanticVectorMath.norm(vector) > 0 ? vector : nil
    }

    /// Drops the loaded model (e.g. when semantic search is turned off) so
    /// its memory is released; the next call reloads it.
    func unload() {
        lock.lock()
        defer { lock.unlock() }
        contextual?.unload()
        contextual = nil
        sentence = nil
        loadedIdentifier = nil
        didLoad = false
    }

    // MARK: - Loading (call with the lock held)

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let model = Self.loadContextualModel() {
            contextual = model
            loadedIdentifier = "nl-contextual:\(model.modelIdentifier):\(model.dimension)"
            return
        }
        if let model = NLEmbedding.sentenceEmbedding(for: .english) {
            sentence = model
            loadedIdentifier = "nl-sentence:en:\(model.dimension)"
        }
    }

    // MARK: - NaturalLanguage API surface (isolated here on purpose)

    /// Loads the contextual embedding model when its assets are on disk.
    /// When they aren't, asks the system to download them (for a later
    /// launch) and returns nil so the sentence embedding is used meanwhile.
    ///
    /// If CI flags an API here, this is the only place `NLContextualEmbedding`
    /// set-up is touched.
    private static func loadContextualModel() -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(language: .english) else { return nil }
        guard model.hasAvailableAssets else {
            model.requestAssets { _, _ in }
            return nil
        }
        do {
            try model.load()
            return model
        } catch {
            Log.intelligence.error("Contextual embedding failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Mean-pools the model's token vectors over the whole text.
    private static func contextualVector(_ model: NLContextualEmbedding, text: String) -> [Double]? {
        let result: NLContextualEmbeddingResult
        // A concrete language (not nil) so this compiles whether or not the
        // parameter is optional; unsupported languages fall back to English.
        let detected: NLLanguage = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        do {
            result = try model.embeddingResult(for: text, language: detected)
        } catch {
            guard let english = try? model.embeddingResult(for: text, language: .english) else { return nil }
            result = english
        }
        let pool = MeanPool(dimension: model.dimension)
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            pool.add(vector)
            return true
        }
        return pool.mean()
    }
}

/// Accumulates token vectors for mean pooling. A reference type so the
/// enumeration block only captures a constant (whatever its sendability).
private final class MeanPool: @unchecked Sendable {
    private var sum: [Double]
    private var count = 0

    init(dimension: Int) {
        sum = [Double](repeating: 0, count: max(dimension, 0))
    }

    func add(_ vector: [Double]) {
        if sum.isEmpty { sum = [Double](repeating: 0, count: vector.count) }
        let n = min(sum.count, vector.count)
        for i in 0..<n { sum[i] += vector[i] }
        count += 1
    }

    func mean() -> [Double]? {
        guard count > 0, !sum.isEmpty else { return nil }
        let divisor = Double(count)
        return sum.map { $0 / divisor }
    }
}
