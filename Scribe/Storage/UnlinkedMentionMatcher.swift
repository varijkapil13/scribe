// Scribe/Storage/UnlinkedMentionMatcher.swift
import Foundation

/// One plain-text mention of a note's title (or alias) that isn't linked.
struct UnlinkedMention: Equatable, Hashable, Sendable, Identifiable {
    /// UTF-16 offset of the mention in the body.
    let location: Int
    /// UTF-16 length of the mention.
    let length: Int
    /// The text as written in the body (original casing).
    let matchedText: String
    /// The title / alias it matched.
    let term: String
    /// 1-based line number.
    let line: Int
    /// The surrounding line (trimmed, shortened) for display.
    let context: String

    var id: Int { location }
}

/// Finds unlinked mentions of a note — its title or frontmatter `aliases:` —
/// in another note's body, and rewrites one occurrence into a `[[link]]`.
///
/// Matching is case-insensitive on whole words (letters, digits and `_` count
/// as word characters) and skips code (fenced blocks, inline code), existing
/// wiki links / embeds, markdown links, bare URLs, HTML comments and
/// `#tags`. Pure and Foundation-only.
enum UnlinkedMentionMatcher {

    /// Shortest term considered — single letters would match everywhere.
    nonisolated static let minimumTermLength = 2

    nonisolated private static let protectedPatterns: [NSRegularExpression] = [
        #"!?\[\[[^\[\]\n]*\]\]"#,                 // wiki links / embeds
        #"!?\[[^\]\n]*\]\([^)\n]*\)"#,            // markdown links / images
        #"<[a-zA-Z][a-zA-Z0-9+.-]*://[^>\s]*>"#,  // autolinks
        #"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#,        // bare URLs
        #"<!--[\s\S]*?-->"#,                      // HTML comments
    ].map {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: $0)
    }

    // MARK: - Terms

    /// Title plus aliases, trimmed, de-duplicated case-insensitively, longest
    /// first (so "Project Plan v2" wins over "Project Plan" at the same spot).
    nonisolated static func terms(title: String, aliases: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in [title] + aliases {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= minimumTermLength else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
        }
        return out.sorted { ($0 as NSString).length > ($1 as NSString).length }
    }

    /// Parses a frontmatter `aliases:` value: `[A, "B, Inc"]`, `A, B` or a
    /// single scalar. Quotes are removed; empty entries dropped.
    nonisolated static func parseAliases(_ raw: String?) -> [String] {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return []
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        var items: [String] = []
        var current = ""
        var quote: Character?
        for ch in value {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Matching

    /// UTF-16 ranges that never hold a mention.
    nonisolated static func protectedRanges(in body: String) -> [NSRange] {
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ranges = MarkdownCodeRanges.codeRanges(in: body)
        for regex in protectedPatterns {
            ranges.append(contentsOf: regex.matches(in: body, range: full).map(\.range))
        }
        return ranges
    }

    /// Every unlinked mention of any of `terms` in `body`, in document order.
    /// Overlapping candidates resolve to the longest term.
    nonisolated static func mentions(of terms: [String], in body: String) -> [UnlinkedMention] {
        let ns = body as NSString
        guard ns.length > 0 else { return [] }
        let protected = protectedRanges(in: body)
        var taken: [NSRange] = []
        var found: [UnlinkedMention] = []
        let full = NSRange(location: 0, length: ns.length)

        let ordered = terms.sorted { ($0 as NSString).length > ($1 as NSString).length }
        for term in ordered where (term as NSString).length >= minimumTermLength {
            let pattern = NSRegularExpression.escapedPattern(for: term)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for m in regex.matches(in: body, range: full) {
                let r = m.range
                guard isWordBoundary(before: r.location, in: ns),
                      isWordBoundary(after: NSMaxRange(r), in: ns) else { continue }
                if r.location > 0 {
                    let prev = ns.character(at: r.location - 1)
                    // `#term` is a tag, `@term` a handle — not prose.
                    if prev == 0x23 || prev == 0x40 { continue }
                }
                if protected.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                if taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                taken.append(r)
                found.append(makeMention(range: r, term: term, in: ns))
            }
        }
        return found.sorted { $0.location < $1.location }
    }

    /// `body` with `mention` replaced by a link to `title` — `[[Title]]` when
    /// the text is the title verbatim, otherwise `[[Title|text]]` so the prose
    /// reads the same. nil when the body no longer holds the mention there
    /// (it changed since the mention was found).
    nonisolated static func linking(_ mention: UnlinkedMention, in body: String, title: String) -> String? {
        let ns = body as NSString
        let range = NSRange(location: mention.location, length: mention.length)
        guard mention.length > 0, NSMaxRange(range) <= ns.length else { return nil }
        guard ns.substring(with: range) == mention.matchedText else { return nil }
        // Still unlinked (not inside code or a link written since)?
        guard mentions(of: [mention.term], in: body).contains(where: { $0.location == mention.location }) else {
            return nil
        }
        let link = mention.matchedText == title
            ? "[[\(title)]]"
            : "[[\(title)|\(mention.matchedText)]]"
        return ns.replacingCharacters(in: range, with: link)
    }

    // MARK: - Helpers

    nonisolated private static func makeMention(range r: NSRange, term: String, in ns: NSString) -> UnlinkedMention {
        let lineRange = ns.lineRange(for: r)
        var context = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        if (context as NSString).length > 160 {
            // Centre a window on the mention.
            let lineText = ns.substring(with: lineRange) as NSString
            let offset = r.location - lineRange.location
            let start = max(0, offset - 70)
            let length = min(lineText.length - start, 160)
            context = (start > 0 ? "…" : "")
                + lineText.substring(with: NSRange(location: start, length: length))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                + (start + length < lineText.length ? "…" : "")
        }
        let line = ns.substring(to: r.location).reduce(into: 1) { count, ch in
            if ch.isNewline { count += 1 }
        }
        return UnlinkedMention(
            location: r.location,
            length: r.length,
            matchedText: ns.substring(with: r),
            term: term,
            line: line,
            context: context
        )
    }

    nonisolated private static func isWordBoundary(before index: Int, in ns: NSString) -> Bool {
        guard index > 0 else { return true }
        return !isWordUnit(ns.character(at: index - 1))
    }

    nonisolated private static func isWordBoundary(after index: Int, in ns: NSString) -> Bool {
        guard index < ns.length else { return true }
        return !isWordUnit(ns.character(at: index))
    }

    /// Letters, digits and `_`. Surrogate halves (astral-plane characters)
    /// count as word characters, conservatively.
    nonisolated private static func isWordUnit(_ unit: unichar) -> Bool {
        if unit == 0x5F { return true }
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
