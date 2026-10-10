// Scribe/Documents/Conversion/MarkdownImportRewriter.swift
//
// Pure Markdown rewriting used by the folder / Notion importers: rewriting
// link and image destinations (outside code), Obsidian `![[embeds]]`, and
// `<img src>` tags; parsing imported frontmatter; naming helpers. Unit tested
// in MarkdownImportRewriterTests.

import Foundation

/// One Markdown link or image found in a document.
struct MarkdownLinkMatch: Equatable {
    var isImage: Bool
    var text: String
    /// The destination as written (without `<…>` wrapping and title).
    var destination: String

    /// `destination` with percent-escapes removed (`My%20Page.md` → `My Page.md`).
    var decodedDestination: String {
        destination.removingPercentEncoding ?? destination
    }

    /// True for `http:`, `https:`, `mailto:` and other scheme URLs.
    var isExternal: Bool {
        MarkdownImportRewriter.hasURLScheme(destination)
    }
}

enum MarkdownImportRewriter {

    // MARK: - Links and images

    private static let linkRegex: NSRegularExpression = {
        // !?[text](<dest> "title") | !?[text](dest "title")
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(!?)\[((?:\\.|[^\]\\])*)\]\(\s*(<[^>\n]*>|[^)\s]+)(\s+"[^"\n]*")?\s*\)"#
        )
    }()

    private static let embedRegex: NSRegularExpression = {
        // Obsidian embeds: ![[file.png]] / ![[file.png|300]]
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!\[\[([^\]\|\n]+)(\|[^\]\n]*)?\]\]"#)
    }()

    private static let imgTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(<img\b[^>]*?\bsrc\s*=\s*)(["'])([^"']*)(\2)"#,
            options: [.caseInsensitive]
        )
    }()

    /// Rewrites every Markdown link / image outside fenced code blocks and
    /// inline code. `transform` returns the full replacement Markdown for a
    /// match, or nil to keep it unchanged.
    static func rewriteLinks(
        in markdown: String,
        transform: (MarkdownLinkMatch) -> String?
    ) -> String {
        rewriteOutsideCode(markdown) { segment in
            replaceMatches(of: linkRegex, in: segment) { match, ns in
                let bang = ns.substring(with: match.range(at: 1))
                let text = ns.substring(with: match.range(at: 2))
                var destination = ns.substring(with: match.range(at: 3))
                if destination.hasPrefix("<"), destination.hasSuffix(">") {
                    destination = String(destination.dropFirst().dropLast())
                }
                return transform(MarkdownLinkMatch(isImage: bang == "!", text: text, destination: destination))
            }
        }
    }

    /// Rewrites Obsidian `![[file]]` embeds outside code. `transform` gets
    /// the target (without the `|size` part) and returns the replacement.
    static func rewriteEmbeds(in markdown: String, transform: (String) -> String?) -> String {
        rewriteOutsideCode(markdown) { segment in
            replaceMatches(of: embedRegex, in: segment) { match, ns in
                let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                return transform(target)
            }
        }
    }

    /// Rewrites `<img src="…">` sources outside code. `transform` gets the
    /// raw src and returns the new src (nil keeps it).
    static func rewriteImageTags(in markdown: String, transform: (String) -> String?) -> String {
        rewriteOutsideCode(markdown) { segment in
            replaceMatches(of: imgTagRegex, in: segment) { match, ns in
                let src = ns.substring(with: match.range(at: 3))
                guard let replacement = transform(src) else { return nil }
                let prefix = ns.substring(with: match.range(at: 1))
                let quote = ns.substring(with: match.range(at: 2))
                return prefix + quote + replacement + quote
            }
        }
    }

    /// Applies `rewrite` to the parts of `markdown` that aren't fenced code
    /// blocks or inline code spans.
    static func rewriteOutsideCode(_ markdown: String, rewrite: (String) -> String) -> String {
        var output: [String] = []
        var fence: String?
        var pending: [String] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            let joined = pending.joined(separator: "\n")
            output.append(rewriteOutsideInlineCode(joined, rewrite: rewrite))
            pending.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let openFence = fence {
                output.append(line)
                if trimmed.hasPrefix(openFence) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushPending()
                fence = String(trimmed.prefix(3))
                output.append(line)
                continue
            }
            pending.append(line)
        }
        flushPending()
        return output.joined(separator: "\n")
    }

    private static func rewriteOutsideInlineCode(_ text: String, rewrite: (String) -> String) -> String {
        guard text.contains("`") else { return rewrite(text) }
        // Even segments are prose, odd ones are inside backticks.
        let parts = text.components(separatedBy: "`")
        // An unbalanced backtick isn't a code span: treat everything as prose.
        guard parts.count % 2 == 1 else { return rewrite(text) }
        return parts.enumerated().map { index, part in
            index % 2 == 0 ? rewrite(part) : part
        }.joined(separator: "`")
    }

    private static func replaceMatches(
        of regex: NSRegularExpression,
        in text: String,
        replacement: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let new = replacement(match, ns) {
                result += new
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - Paths

    static func hasURLScheme(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":") else { return false }
        let scheme = destination[..<colon]
        guard let first = scheme.first, first.isLetter, scheme.count >= 2 else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Resolves a relative link destination against the folder of the
    /// document that contains it (both vault-/export-relative, `/`-separated).
    /// Returns nil for paths escaping the root.
    static func resolveRelative(_ destination: String, fromFolder folder: String) -> String? {
        var path = destination
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        guard !path.isEmpty else { return nil }
        var components: [String] = path.hasPrefix("/")
            ? []
            : folder.split(separator: "/").map(String.init)
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(String(part))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    // MARK: - Notion

    private static let notionIdRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^(.*?)[ _-]*(?<![0-9A-Za-z])([0-9a-fA-F]{32})$"#)
    }()

    /// Strips Notion's 32-hex id suffix: `Meeting Notes 0a1b…9f` →
    /// `Meeting Notes`. Names without one are returned trimmed.
    static func stripNotionId(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let match = notionIdRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else {
            return trimmed
        }
        let base = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? trimmed : base
    }

    /// Notion page title for an exported file name (`Page abc….md` → `Page`).
    static func notionTitle(forFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return stripNotionId(base)
    }

    // MARK: - Titles

    /// First of `title`, `title 2`, `title 3`, … not in `taken` (compared
    /// case-insensitively); the result is inserted into `taken`.
    static func uniqueTitle(_ title: String, taken: inout Set<String>) -> String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Removes a leading `# Title` line when it repeats the note's title
    /// (Notion and many exporters start the body with it).
    static func removingLeadingTitleHeading(_ body: String, title: String) -> String {
        var lines = body.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first else { return body }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# ") else { return body }
        let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard heading.caseInsensitiveCompare(title) == .orderedSame else { return body }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: - Frontmatter

    /// Metadata pulled from an imported Markdown file's frontmatter.
    struct ImportedFrontmatter: Equatable {
        var title: String?
        var tags: [String] = []
        var created: Date?
        var updated: Date?
        /// Other simple `key: value` pairs, kept verbatim.
        var extra: [FrontmatterEntry] = []
    }

    /// Keys that are Scribe-owned (or would confuse Scribe) and are never
    /// copied from an imported file.
    static let droppedFrontmatterKeys: Set<String> = [
        "id", "notebookId", "isDailyNote", "dailyDate", "locked",
    ]

    /// Splits a Markdown file into its frontmatter (YAML subset: scalars,
    /// inline `[a, b]` lists and `- item` block lists) and body. Files
    /// without a frontmatter block return empty metadata and the whole text.
    static func splitFrontmatter(_ contents: String) -> (ImportedFrontmatter, String) {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") {
            lines[0] = String(first.dropFirst())
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return (ImportedFrontmatter(), lines.joined(separator: "\n"))
        }
        let header = Array(lines[1..<close])
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)

        var meta = ImportedFrontmatter()
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var list: [String]?
            if value.isEmpty {
                // Block list:  key:\n  - a\n  - b
                var items: [String] = []
                while index < header.count {
                    let item = header[index].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("- ") || item == "-" else { break }
                    items.append(unquote(String(item.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                if !items.isEmpty { list = items.filter { !$0.isEmpty } }
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                list = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
            }
            switch key.lowercased() {
            case "title":
                let title = unquote(value)
                if !title.isEmpty { meta.title = title }
            case "tags", "tag", "keywords":
                if let list {
                    meta.tags += list
                } else {
                    meta.tags += unquote(value)
                        .split(whereSeparator: { $0 == "," || $0 == " " })
                        .map(String.init)
                }
            case "created", "date", "created_at", "creation date", "date created":
                meta.created = parseDate(unquote(value))
            case "updated", "modified", "updated_at", "last modified", "date modified":
                meta.updated = parseDate(unquote(value))
            default:
                guard !droppedFrontmatterKeys.contains(key) else { continue }
                if let list {
                    value = "[" + list.joined(separator: ", ") + "]"
                }
                if !value.isEmpty {
                    meta.extra.append(FrontmatterEntry(key: key, value: value))
                }
            }
        }
        meta.tags = meta.tags
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (meta, body)
    }

    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let first = trimmed.first, let last = trimmed.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// ISO 8601 (with or without time / fractional seconds), `yyyy-MM-dd`,
    /// `yyyy-MM-dd HH:mm[:ss]`, and Notion's `January 5, 2024 3:04 PM`.
    static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                       "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "MMMM d, yyyy h:mm a", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    // MARK: - CSV

    /// Parses CSV (RFC 4180: quoted fields, `""` escapes, embedded newlines,
    /// CRLF, a leading BOM). Empty trailing lines are dropped.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// A Markdown table for CSV rows (first row = header). `linkFirstColumn`
    /// turns first-column values into `[[wiki links]]` when it returns true.
    static func markdownTable(fromCSV rows: [[String]], linkFirstColumn: (String) -> Bool = { _ in false }) -> String {
        guard let header = rows.first, !header.isEmpty else { return "" }
        let columns = rows.map(\.count).max() ?? header.count
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespaces)
        }
        func line(_ values: [String]) -> String {
            let padded = values + Array(repeating: "", count: max(0, columns - values.count))
            return "| " + padded.map(cell).joined(separator: " | ") + " |"
        }
        var lines = [line(header), "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"]
        for row in rows.dropFirst() {
            var values = row
            if let first = values.first, !first.isEmpty, linkFirstColumn(first) {
                values[0] = "[[\(first)]]"
            }
            lines.append(line(values))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Recognized text

    /// Plain recognized text made safe to place in Markdown: lines that
    /// would start a heading / list / quote are escaped, blank runs collapsed.
    static func escapedPlainText(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var lastBlank = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lastBlank, !out.isEmpty { out.append("") }
                lastBlank = true
                continue
            }
            lastBlank = false
            var escaped = HTMLMarkdownRenderer.escapeLineStart(line)
            if escaped.hasPrefix("```") || escaped.hasPrefix("~~~") || escaped.hasPrefix("<") {
                escaped = "\\" + escaped
            }
            out.append(escaped)
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
