// Scribe/Intelligence/Semantic/SemanticVectorMath.swift
import Accelerate
import Foundation

/// Vector math for semantic search, on Accelerate (vDSP). Pure and
/// thread-safe; every function works on plain `[Float]` values.
enum SemanticVectorMath {

    /// One scored row of a similarity search.
    struct Scored: Equatable, Sendable {
        var index: Int
        var score: Float
    }

    /// Euclidean length.
    nonisolated static func norm(_ vector: [Float]) -> Float {
        guard !vector.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        return sumOfSquares.squareRoot()
    }

    /// The vector scaled to unit length (unchanged when it is all zeros).
    nonisolated static func normalized(_ vector: [Float]) -> [Float] {
        let length = norm(vector)
        guard length > 0, length.isFinite else { return vector }
        var divisor = length
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// Dot product; 0 when the lengths differ or either is empty.
    nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Cosine similarity in [-1, 1]; 0 when the lengths differ or either
    /// vector is all zeros.
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let denominator = norm(a) * norm(b)
        guard denominator > 0 else { return 0 }
        return dot(a, b) / denominator
    }

    /// Similarity of `query` against every row of a row-major matrix of
    /// `rows` × `dimension` values. With unit-length rows and query this is
    /// the cosine similarity. One `vDSP_mmul` for the whole index.
    nonisolated static func scores(query: [Float], matrix: [Float], rows: Int, dimension: Int) -> [Float] {
        guard rows > 0, dimension > 0, query.count == dimension, matrix.count >= rows * dimension else { return [] }
        var out = [Float](repeating: 0, count: rows)
        // (rows × dimension) · (dimension × 1) = (rows × 1)
        vDSP_mmul(matrix, 1, query, 1, &out, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
        return out
    }

    /// The `k` best rows (highest score first; ties by lower index).
    /// Rows scoring below `minimumScore` are skipped.
    nonisolated static func topK(query: [Float], matrix: [Float], rows: Int, dimension: Int,
                                 k: Int, minimumScore: Float = -Float.greatestFiniteMagnitude) -> [Scored] {
        guard k > 0 else { return [] }
        let all = scores(query: query, matrix: matrix, rows: rows, dimension: dimension)
        return topK(scores: all, k: k, minimumScore: minimumScore)
    }

    /// The `k` best entries of a score list.
    nonisolated static func topK(scores: [Float], k: Int,
                                 minimumScore: Float = -Float.greatestFiniteMagnitude) -> [Scored] {
        guard k > 0 else { return [] }
        let candidates = scores.indices.filter { scores[$0] >= minimumScore && scores[$0].isFinite }
        let sorted = candidates.sorted { lhs, rhs in
            if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
            return lhs < rhs
        }
        return sorted.prefix(k).map { Scored(index: $0, score: scores[$0]) }
    }
}
