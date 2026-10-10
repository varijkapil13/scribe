// Scribe/Shared/ScribeMarkdownPreviewParser.swift
//
// Block-level Markdown splitter for the Quick Look preview extension
// (ScribeQuickLook renders each block into an NSAttributedString; inline
// emphasis / code / links go through Foundation's `AttributedString(markdown:)`
// there). Deliberately small: headings, paragraphs, lists (incl. task
// checkboxes), quotes, fenced code and rules — enough for a faithful
// preview of a Scribe note, with no dependencies. Foundation-only; shared
// with the extension via project.yml and unit-tested in ScribeTests.

import Foundation

enum ScribeMarkdownPreviewBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, marker: String, text: String)
    case task(indent: Int, isChecked: Bool, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule
}

struct ScribeMarkdownPreviewDocument: Equatable, Sendable {
    /// `title:` from YAML frontmatter, when present.
    var title: String?
    var blocks: [ScribeMarkdownPreviewBlock]
}

enum ScribeMarkdownPreviewParser {

    // MARK: - Frontmatter

    /// Splits a leading `---` … `---` (or `...`) YAML block off `text`.
    /// Returns the simple `key: value` pairs (keys lower-cased, quotes
    /// stripped) and the remaining body. Text without a closed frontmatter
    /// block is returned unchanged.
    static func splitFrontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], normalized)
        }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                let body = lines[(index + 1)...].joined(separator: "\n")
                return (fields, body)
            }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty, fields[key] == nil { fields[key] = value }
            }
            index += 1
        }
        // Never closed: not frontmatter after all.
        return ([:], normalized)
    }

    // MARK: - Blocks

    static func parse(_ text: String) -> ScribeMarkdownPreviewDocument {
        let (fields, body) = splitFrontmatter(text)
        let title = fields["title"].flatMap { $0.isEmpty ? nil : $0 }
        return ScribeMarkdownPreviewDocument(title: title, blocks: blocks(from: body))
    }

    static func blocks(from body: String) -> [ScribeMarkdownPreviewBlock] {
        var blocks: [ScribeMarkdownPreviewBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }

        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a fenced code block: everything verbatim until the fence closes.
            if var open = fence {
                if trimmed.hasPrefix(open.marker) && trimmed.allSatisfy({ String($0) == String(open.marker.prefix(1)) }) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(rawLine)
                    fence = open
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if let marker = fenceMarker(trimmed) {
                flushParagraph()
                flushQuote()
                let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker: marker, language: info.isEmpty ? nil : info, lines: [])
                continue
            }

            // Setext heading underline directly below paragraph text.
            if !paragraph.isEmpty, isSetextUnderline(trimmed) {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                let text = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: level, text: text))
                continue
            }

            if let heading = atxHeading(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(heading)
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                quote.append(content)
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                blocks.append(item)
                continue
            }

            flushQuote()
            paragraph.append(trimmed)
        }

        if let open = fence {
            // Unclosed fence: still show what was there.
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    // MARK: - Line classifiers

    private static func fenceMarker(_ trimmed: String) -> String? {
        for char in ["`", "~"] {
            let run = trimmed.prefix { String($0) == char }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func atxHeading(_ trimmed: String) -> ScribeMarkdownPreviewBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes ("## Title ##").
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// `- item`, `* item`, `+ item`, `1. item`, `1) item`, `- [ ] task`,
    /// `- [x] task`. Indent is the leading-space count / 2.
    private static func listItem(_ line: String) -> ScribeMarkdownPreviewBlock? {
        let leading = line.prefix { $0 == " " }.count
        let indent = leading / 2
        let content = line.dropFirst(leading)

        if let bullet = content.first, "-*+".contains(bullet), content.dropFirst().hasPrefix(" ") {
            let text = content.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let task = taskItem(text, indent: indent) { return task }
            return .bullet(indent: indent, text: text)
        }

        let digits = content.prefix { $0.isASCII && $0.isNumber }
        if (1...9).contains(digits.count) {
            let afterDigits = content.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
               afterDigits.dropFirst().hasPrefix(" ") {
                let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return .numbered(indent: indent, marker: "\(digits)\(delimiter)", text: text)
            }
        }
        return nil
    }

    private static func taskItem(_ text: String, indent: Int) -> ScribeMarkdownPreviewBlock? {
        let lower = text.lowercased()
        for (box, checked) in [("[ ]", false), ("[x]", true)] where lower.hasPrefix(box) {
            let rest = text.dropFirst(3)
            guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
            return .task(indent: indent, isChecked: checked, text: rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
