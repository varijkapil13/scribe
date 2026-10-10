// Scribe/Storage/NoteLineDiff.swift
import Foundation

/// A simple line-based diff (longest common subsequence) for the version
/// history view. Pure.
enum NoteLineDiff {

    enum Kind: String, Equatable, Sendable {
        case unchanged
        case added
        case removed
    }

    struct Line: Equatable, Sendable {
        let kind: Kind
        let text: String
        /// 1-based line in the old text (nil for added lines).
        let oldNumber: Int?
        /// 1-based line in the new text (nil for removed lines).
        let newNumber: Int?
    }

    /// Above this many LCS cells the middle section is shown as a block
    /// replacement instead (keeps huge notes responsive).
    nonisolated static let maxCells = 4_000_000

    /// Lines of `new` compared with `old`, in display order (removals before
    /// the additions that replace them).
    nonisolated static func diff(old: String, new: String) -> [Line] {
        let a = split(old)
        let b = split(new)

        // Common prefix / suffix are trivially unchanged.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        var out: [Line] = []
        for i in 0..<prefix {
            out.append(Line(kind: .unchanged, text: a[i], oldNumber: i + 1, newNumber: i + 1))
        }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        out.append(contentsOf: middle(aMid, bMid, oldOffset: prefix, newOffset: prefix))

        for k in 0..<suffix {
            let i = a.count - suffix + k
            let j = b.count - suffix + k
            out.append(Line(kind: .unchanged, text: a[i], oldNumber: i + 1, newNumber: j + 1))
        }
        return out
    }

    /// Counts of added / removed lines.
    nonisolated static func summary(_ lines: [Line]) -> (added: Int, removed: Int) {
        lines.reduce(into: (added: 0, removed: 0)) { acc, line in
            switch line.kind {
            case .added: acc.added += 1
            case .removed: acc.removed += 1
            case .unchanged: break
            }
        }
    }

    // MARK: - Private

    nonisolated private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    nonisolated private static func middle(_ a: [String], _ b: [String], oldOffset: Int, newOffset: Int) -> [Line] {
        let n = a.count
        let m = b.count
        if n == 0 && m == 0 { return [] }
        if n == 0 || m == 0 || n * m > maxCells {
            var block: [Line] = []
            for (k, text) in a.enumerated() {
                block.append(Line(kind: .removed, text: text, oldNumber: oldOffset + k + 1, newNumber: nil))
            }
            for (k, text) in b.enumerated() {
                block.append(Line(kind: .added, text: text, oldNumber: nil, newNumber: newOffset + k + 1))
            }
            return block
        }

        // lcs[i][j] = LCS length of a[i...] and b[j...], flattened.
        let width = m + 1
        var lcs = [Int32](repeating: 0, count: (n + 1) * width)
        var i = n - 1
        while i >= 0 {
            var j = m - 1
            while j >= 0 {
                if a[i] == b[j] {
                    lcs[i * width + j] = lcs[(i + 1) * width + j + 1] + 1
                } else {
                    lcs[i * width + j] = max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
                j -= 1
            }
            i -= 1
        }

        var out: [Line] = []
        var x = 0
        var y = 0
        while x < n && y < m {
            if a[x] == b[y] {
                out.append(Line(kind: .unchanged, text: a[x], oldNumber: oldOffset + x + 1, newNumber: newOffset + y + 1))
                x += 1
                y += 1
            } else if lcs[(x + 1) * width + y] >= lcs[x * width + y + 1] {
                out.append(Line(kind: .removed, text: a[x], oldNumber: oldOffset + x + 1, newNumber: nil))
                x += 1
            } else {
                out.append(Line(kind: .added, text: b[y], oldNumber: nil, newNumber: newOffset + y + 1))
                y += 1
            }
        }
        while x < n {
            out.append(Line(kind: .removed, text: a[x], oldNumber: oldOffset + x + 1, newNumber: nil))
            x += 1
        }
        while y < m {
            out.append(Line(kind: .added, text: b[y], oldNumber: nil, newNumber: newOffset + y + 1))
            y += 1
        }
        return out
    }
}
