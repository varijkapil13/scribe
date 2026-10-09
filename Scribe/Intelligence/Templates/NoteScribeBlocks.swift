import Foundation

/// Pure helpers for Scribe-owned, delimited blocks inside a note body.
///
/// A block looks like:
///
///     <!-- scribe:summary:<sessionId> -->
///     …generated markdown…
///     <!-- /scribe:summary -->
///
/// The HTML-comment markers are invisible in rendered markdown (and in other
/// markdown apps), and let Scribe replace its own generated content in place
/// without ever touching text the user typed around it. Any `kind` works
/// (`summary`, …); everything outside blocks is "user content".
enum NoteScribeBlocks {

    struct Block: Equatable {
        let kind: String
        let id: String
        /// Range of the whole block, markers included.
        let range: Range<String.Index>
        /// The inner text between the markers, trimmed.
        let content: String
    }

    static let summaryKind = "summary"

    static func startMarker(kind: String, id: String) -> String {
        "<!-- scribe:\(kind):\(id) -->"
    }

    static func endMarker(kind: String) -> String {
        "<!-- /scribe:\(kind) -->"
    }

    /// Full block text for `content`, markers included.
    static func render(kind: String, id: String, content: String) -> String {
        startMarker(kind: kind, id: id) + "\n"
            + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            + endMarker(kind: kind)
    }

    /// Every well-formed block in `body`, in document order. An opening marker
    /// without a matching close is ignored (treated as user text).
    static func blocks(in body: String) -> [Block] {
        var out: [Block] = []
        var searchStart = body.startIndex
        let openToken = "<!-- scribe:"
        while searchStart < body.endIndex,
              let open = body.range(of: openToken, range: searchStart..<body.endIndex) {
            guard let headerEnd = body.range(of: "-->", range: open.upperBound..<body.endIndex) else {
                break
            }
            let header = body[open.upperBound..<headerEnd.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let kind = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let id = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            guard !kind.isEmpty,
                  let close = body.range(of: endMarker(kind: kind),
                                         range: headerEnd.upperBound..<body.endIndex)
            else {
                searchStart = headerEnd.upperBound
                continue
            }
            let inner = String(body[headerEnd.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Block(kind: kind, id: id, range: open.lowerBound..<close.upperBound, content: inner))
            searchStart = close.upperBound
        }
        return out
    }

    /// Inserts or replaces the block `(kind, id)`. Replacement happens in place
    /// (surrounding text untouched); a new block is appended at the end of the
    /// body after a blank line.
    static func upsert(body: String, kind: String, id: String, content: String) -> String {
        let rendered = render(kind: kind, id: id, content: content)
        if let existing = blocks(in: body).first(where: { $0.kind == kind && $0.id == id }) {
            var out = body
            out.replaceSubrange(existing.range, with: rendered)
            return out
        }
        let trimmed = trimTrailingWhitespace(body)
        if trimmed.isEmpty { return rendered + "\n" }
        return trimmed + "\n\n" + rendered + "\n"
    }

    static func upsertSummary(body: String, sessionId: String, content: String) -> String {
        upsert(body: body, kind: summaryKind, id: sessionId, content: content)
    }

    /// Inner content of block `(kind, id)`, or nil.
    static func extract(body: String, kind: String, id: String) -> String? {
        blocks(in: body).first(where: { $0.kind == kind && $0.id == id })?.content
    }

    static func extractSummary(body: String, sessionId: String) -> String? {
        extract(body: body, kind: summaryKind, id: sessionId)
    }

    /// Removes block `(kind, id)` (and collapses the blank lines it leaves).
    static func remove(body: String, kind: String, id: String) -> String {
        guard let existing = blocks(in: body).first(where: { $0.kind == kind && $0.id == id }) else {
            return body
        }
        var out = body
        out.removeSubrange(existing.range)
        return collapseBlankLines(out)
    }

    /// The note body with every Scribe block removed — i.e. what the user
    /// typed. Trimmed, with runs of blank lines collapsed.
    static func userContent(body: String) -> String {
        // Rebuild from the slices between blocks (indices stay valid because
        // `body` itself is never mutated).
        var out = ""
        var cursor = body.startIndex
        for block in blocks(in: body) {
            out.append(contentsOf: body[cursor..<block.range.lowerBound])
            cursor = block.range.upperBound
        }
        out.append(contentsOf: body[cursor...])
        return collapseBlankLines(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the user's content with `newUserContent`, keeping every Scribe
    /// block (in order) after it.
    static func replaceUserContent(body: String, with newUserContent: String) -> String {
        let kept = blocks(in: body).map { String(body[$0.range]) }
        let user = newUserContent.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !user.isEmpty { parts.append(user) }
        parts.append(contentsOf: kept)
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Appends a `## heading` section to the end of the body.
    static func appendSection(body: String, heading: String, content: String) -> String {
        let section = "## \(heading)\n\n" + content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = trimTrailingWhitespace(body)
        if trimmed.isEmpty { return section + "\n" }
        return trimmed + "\n\n" + section + "\n"
    }

    // MARK: - Private

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var out = s
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }

    /// Collapses 3+ consecutive newlines into exactly 2.
    static func collapseBlankLines(_ s: String) -> String {
        var out = ""
        var newlineRun = 0
        for ch in s {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun <= 2 { out.append(ch) }
            } else {
                newlineRun = 0
                out.append(ch)
            }
        }
        return out
    }
}
