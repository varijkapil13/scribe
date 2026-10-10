// Scribe/Storage/NoteBlockReference.swift
import Foundation

/// Pure helpers for heading sections and `^block-id` anchors inside a note
/// body — the targets of `[[Note#Heading]]`, `[[Note#^block-id]]` and their
/// `![[…]]` embeds.
///
/// A block id is written Obsidian-style at the end of a paragraph or list
/// item: `Some paragraph text ^abc123`. A `^id` alone on the line after a
/// block (used for tables / quotes) anchors that preceding block. Lines inside
/// fenced code blocks are never headings or anchors.
enum NoteBlockReference {

    /// `^id` at the end of a line, preceded by whitespace or the line start.
    nonisolated static let blockIdPattern = #"(?:^|\s)\^([A-Za-z0-9][A-Za-z0-9_-]*)\s*$"#

    nonisolated private static let blockIdRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: blockIdPattern)
    }()

    nonisolated private static let headingRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    }()

    nonisolated private static let listItemRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d+[.)])[ \t]+"#)
    }()

    // MARK: - Line model

    /// Splits `body` into lines (`\n`, tolerating `\r\n`).
    nonisolated static func lines(of body: String) -> [String] {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    /// For each line, whether it belongs to a fenced code block (the fence
    /// lines themselves included).
    nonisolated static func fencedLineMask(_ lines: [String]) -> [Bool] {
        var mask = Array(repeating: false, count: lines.count)
        var openFence: String?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                mask[i] = true
                // A closing fence is a run of the same character, at least
                // as long as the opening one, and nothing else.
                if let fenceChar = fence.first,
                   trimmed.count >= fence.count,
                   trimmed.allSatisfy({ $0 == fenceChar }) {
                    openFence = nil
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker: Character = trimmed.hasPrefix("```") ? "`" : "~"
                openFence = String(trimmed.prefix { $0 == marker })
                mask[i] = true
            }
        }
        return mask
    }

    /// `(level, text)` when `line` is an ATX heading.
    nonisolated static func heading(in line: String) -> (level: Int, text: String)? {
        let ns = line as NSString
        guard let m = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let level = m.range(at: 1).length
        let text = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    /// The `^id` anchoring `line`, if any.
    nonisolated static func blockId(in line: String) -> String? {
        let ns = line as NSString
        guard let m = blockIdRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    /// `line` without its trailing `^id` anchor.
    nonisolated static func strippingBlockId(_ line: String) -> String {
        let ns = line as NSString
        guard let m = blockIdRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return line
        }
        var out = ns.substring(to: m.range.location)
        while out.last == " " || out.last == "\t" { out.removeLast() }
        return out
    }

    /// Every block id in `body` (outside code), in order.
    nonisolated static func blockIds(in body: String) -> [String] {
        let all = lines(of: body)
        let fenced = fencedLineMask(all)
        return all.enumerated().compactMap { i, line in fenced[i] ? nil : blockId(in: line) }
    }

    // MARK: - Lookup

    /// 0-based line index of the heading whose text matches `heading`
    /// (case-insensitive, whitespace-trimmed).
    nonisolated static func headingLineIndex(_ heading: String, in body: String) -> Int? {
        let wanted = normalize(heading)
        let all = lines(of: body)
        let fenced = fencedLineMask(all)
        for (i, line) in all.enumerated() where !fenced[i] {
            if let h = Self.heading(in: line), normalize(h.text) == wanted { return i }
        }
        return nil
    }

    /// 0-based index of the line carrying `^id`.
    nonisolated static func blockLineIndex(_ id: String, in body: String) -> Int? {
        let all = lines(of: body)
        let fenced = fencedLineMask(all)
        for (i, line) in all.enumerated() where !fenced[i] {
            if blockId(in: line) == id { return i }
        }
        return nil
    }

    /// 0-based line the link target points at (heading or block), or nil
    /// when the target has no fragment or it isn't found.
    nonisolated static func lineIndex(for target: WikiLinkTarget, in body: String) -> Int? {
        if let blockId = target.blockId { return blockLineIndex(blockId, in: body) }
        if let heading = target.heading { return headingLineIndex(heading, in: body) }
        return nil
    }

    /// The heading's section: the heading line through the line before the
    /// next heading of the same or a higher level.
    nonisolated static func headingSection(_ heading: String, in body: String) -> String? {
        let all = lines(of: body)
        let fenced = fencedLineMask(all)
        guard let start = headingLineIndex(heading, in: body),
              let level = Self.heading(in: all[start])?.level else { return nil }
        var end = all.count
        var i = start + 1
        while i < all.count {
            if !fenced[i], let h = Self.heading(in: all[i]), h.level <= level {
                end = i
                break
            }
            i += 1
        }
        return trimBlankEdges(Array(all[start..<end])).joined(separator: "\n")
    }

    /// The paragraph / list item anchored by `^id`, with the anchor removed.
    nonisolated static func block(_ id: String, in body: String) -> String? {
        let all = lines(of: body)
        let fenced = fencedLineMask(all)
        guard let index = blockLineIndex(id, in: body) else { return nil }
        let isBlank: (Int) -> Bool = { all[$0].trimmingCharacters(in: .whitespaces).isEmpty }

        // `^id` alone on its line: it anchors the block just above.
        if strippingBlockId(all[index]).trimmingCharacters(in: .whitespaces).isEmpty {
            var end = index - 1
            while end >= 0 && isBlank(end) { end -= 1 }
            guard end >= 0 else { return nil }
            var start = end
            while start - 1 >= 0 && !isBlank(start - 1) { start -= 1 }
            return Array(all[start...end]).joined(separator: "\n")
        }

        // A list item: the item plus its more-indented continuation lines.
        if let indent = listItemIndent(all[index]) {
            var end = index
            var j = index + 1
            while j < all.count, !isBlank(j), indentWidth(all[j]) > indent {
                end = j
                j += 1
            }
            var out = Array(all[index...end])
            out[0] = strippingBlockId(out[0])
            return out.joined(separator: "\n")
        }

        // A paragraph: expand to the surrounding blank lines / headings.
        var start = index
        while start - 1 >= 0, !isBlank(start - 1), !fenced[start - 1],
              heading(in: all[start - 1]) == nil, listItemIndent(all[start - 1]) == nil {
            start -= 1
        }
        var end = index
        while end + 1 < all.count, !isBlank(end + 1), !fenced[end + 1],
              heading(in: all[end + 1]) == nil, listItemIndent(all[end + 1]) == nil {
            end += 1
        }
        var out = Array(all[start...end])
        out[index - start] = strippingBlockId(out[index - start])
        return out.joined(separator: "\n")
    }

    /// The content a link / embed target designates inside `body`: the
    /// heading section, the anchored block, or the whole body. nil when the
    /// fragment doesn't exist.
    nonisolated static func content(for target: WikiLinkTarget, in body: String) -> String? {
        if let blockId = target.blockId { return block(blockId, in: body) }
        if let heading = target.heading { return headingSection(heading, in: body) }
        return body
    }

    // MARK: - Helpers

    nonisolated private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    nonisolated private static func listItemIndent(_ line: String) -> Int? {
        let ns = line as NSString
        guard listItemRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else {
            return nil
        }
        return indentWidth(line)
    }

    /// Leading whitespace width (tab = 4).
    nonisolated private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width += 4 } else { break }
        }
        return width
    }

    nonisolated private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var out = lines
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        while let first = out.first, first.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        return out
    }
}
