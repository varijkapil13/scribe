// Scribe/Intelligence/Translation/TranslationPlanning.swift
import Foundation

/// Pure planning for "Translate Note…" / "Translate Transcript…": which
/// pieces of text go to the translator, how the translated pieces are put
/// back together, and what the resulting note looks like. The translation
/// itself (Apple's Translation framework) lives in `ScribeTranslationRunner`.
///
/// Translations are always written to a NEW note; the original note and
/// transcript are never modified.

// MARK: - Markdown

/// A markdown body split into lines that are kept verbatim (blank lines,
/// code blocks, front matter, rules) and lines whose prose is translated
/// with its markup prefix (heading, list, quote, checkbox) kept as-is.
struct MarkdownTranslationPlan: Equatable, Sendable {

    enum Line: Equatable, Sendable {
        case verbatim(String)
        /// `prefix` is kept; `text` is translated.
        case translate(prefix: String, text: String)
    }

    var lines: [Line]

    /// The texts to translate, in order.
    var texts: [String] {
        lines.compactMap { line in
            if case .translate(_, let text) = line { return text }
            return nil
        }
    }

    nonisolated init(lines: [Line]) {
        self.lines = lines
    }

    nonisolated init(markdown: String) {
        var out: [Line] = []
        var inFence = false
        var inFrontMatter = false
        let rawLines = markdown.components(separatedBy: "\n")
        for (index, raw) in rawLines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if index == 0 && trimmed == "---" {
                inFrontMatter = true
                out.append(.verbatim(raw))
                continue
            }
            if inFrontMatter {
                out.append(.verbatim(raw))
                if trimmed == "---" { inFrontMatter = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                out.append(.verbatim(raw))
                continue
            }
            if inFence || trimmed.isEmpty || Self.isRule(trimmed) || Self.isTableSeparator(trimmed) {
                out.append(.verbatim(raw))
                continue
            }
            let (prefix, text) = Self.splitPrefix(raw)
            if text.trimmingCharacters(in: .whitespaces).isEmpty || !text.contains(where: \.isLetter) {
                out.append(.verbatim(raw))
            } else {
                out.append(.translate(prefix: prefix, text: text))
            }
        }
        self.lines = out
    }

    /// Rebuilds the markdown with `translations` (one per entry of
    /// ``texts``, in order). Missing translations keep the original text.
    nonisolated func render(translations: [String]) -> String {
        var index = 0
        var out: [String] = []
        for line in lines {
            switch line {
            case .verbatim(let raw):
                out.append(raw)
            case .translate(let prefix, let text):
                let translated = index < translations.count ? translations[index] : text
                index += 1
                let single = translated.replacingOccurrences(of: "\n", with: " ")
                out.append(prefix + single)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Splits leading whitespace and markdown markers from the prose.
    nonisolated static func splitPrefix(_ raw: String) -> (prefix: String, text: String) {
        var prefixEnd = raw.startIndex
        // Leading indentation.
        while prefixEnd < raw.endIndex, raw[prefixEnd] == " " || raw[prefixEnd] == "\t" {
            prefixEnd = raw.index(after: prefixEnd)
        }
        var rest = raw[prefixEnd...]
        var consumed = true
        while consumed {
            consumed = false
            for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "> ", "- ", "* ", "+ "] where rest.hasPrefix(marker) {
                rest = rest.dropFirst(marker.count)
                consumed = true
                break
            }
            if !consumed, rest.hasPrefix("#") {
                let hashCount = rest.prefix(while: { $0 == "#" }).count
                if hashCount <= 6, rest.dropFirst(hashCount).hasPrefix(" ") {
                    rest = rest.dropFirst(hashCount + 1)
                    consumed = true
                }
            }
            if !consumed {
                let digits = rest.prefix(while: \.isNumber)
                if !digits.isEmpty {
                    let after = rest.dropFirst(digits.count)
                    if after.hasPrefix(". ") || after.hasPrefix(") ") {
                        rest = after.dropFirst(2)
                        consumed = true
                    }
                }
            }
        }
        let prefix = String(raw[raw.startIndex..<rest.startIndex])
        return (prefix, String(rest))
    }

    nonisolated static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    nonisolated static func isTableSeparator(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.allSatisfy { "|-: ".contains($0) }
    }
}

// MARK: - Transcript

/// One transcript line to translate.
struct TranscriptTranslationLine: Equatable, Sendable {
    var speaker: String
    var timestamp: String
    var text: String
}

// MARK: - Output

enum ScribeTranslationOutput {

    /// "Weekly Sync (German)".
    nonisolated static func noteTitle(original: String, languageName: String) -> String {
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "Untitled" : base) (\(languageName))"
    }

    /// Header linking back to the untouched original.
    nonisolated static func header(originalTitle: String, languageName: String, what: String) -> String {
        let title = originalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = title.isEmpty ? "the original note" : "[[\(title)]]"
        return "> Translated \(what) of \(link) into \(languageName) on this Mac. The original is unchanged."
    }

    /// Body of a translated note.
    nonisolated static func noteBody(originalTitle: String, languageName: String, translatedMarkdown: String) -> String {
        header(originalTitle: originalTitle, languageName: languageName, what: "note")
            + "\n\n" + translatedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Body of a translated transcript: one paragraph per line,
    /// `**Speaker** [00:01:02]: text`.
    nonisolated static func transcriptBody(originalTitle: String,
                                           sessionTitle: String,
                                           languageName: String,
                                           lines: [TranscriptTranslationLine],
                                           translations: [String]) -> String {
        var parts: [String] = [
            header(originalTitle: originalTitle, languageName: languageName, what: "transcript"),
            "## \(sessionTitle.isEmpty ? "Transcript" : sessionTitle) (\(languageName))"
        ]
        for (index, line) in lines.enumerated() {
            let text = index < translations.count ? translations[index] : line.text
            let speaker = line.speaker.isEmpty ? "" : "**\(line.speaker)** "
            parts.append("\(speaker)\(line.timestamp): \(text)")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Splits `items` into batches of at most `size` (for progress and to
    /// keep each translation request small).
    nonisolated static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
