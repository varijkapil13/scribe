import Foundation

// MARK: - Custom vocabulary (personal dictionary)
//
// Pure, Foundation-only model for the user's vocabulary list. Two jobs:
//
// 1. **Terms** (names, jargon, product words) are handed to the speech
//    transcriber as contextual strings when a pipeline starts, nudging the
//    recognizer towards the right spelling (see
//    `TranscriptionPipeline+Vocabulary.swift`).
// 2. **Corrections** ("heard as → replace with") are applied to finalized
//    text by `VocabularyCorrector` — whole-word, case-insensitive — for both
//    meeting segments and dictation. This path works even when the
//    recognizer ignores the contextual hints.
//
// Storage: a plain markdown file at
// `~/Library/Application Support/Scribe/vocabulary.md` (see
// `VocabularyStore`), so it can also be edited by hand or synced.

/// One line of the vocabulary list.
struct VocabularyEntry: Equatable, Hashable, Identifiable, Sendable {
    /// The canonical spelling, e.g. `"Kubernetes"` or `"kubectl"`. Always
    /// handed to the transcriber as a contextual string.
    var term: String
    /// What the recognizer tends to write instead (e.g. `"cube control"`).
    /// When set, finalized text containing this phrase is rewritten to `term`.
    var heardAs: String?

    init(term: String, heardAs: String? = nil) {
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heardAs?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.heardAs = (heard?.isEmpty ?? true) ? nil : heard
    }

    var id: String {
        if let heardAs { return VocabularyCorrector.normalize(heardAs) + "\u{1F}" + term }
        return term
    }

    /// The correction this entry contributes, if any. A correction whose
    /// source and target are byte-identical is a no-op and is dropped.
    var correction: VocabularyCorrection? {
        guard let heardAs, !term.isEmpty, heardAs != term else { return nil }
        return VocabularyCorrection(heardAs: heardAs, replacement: term)
    }
}

/// A single "heard as → replace with" rule.
struct VocabularyCorrection: Equatable, Hashable, Sendable {
    let heardAs: String
    let replacement: String
}

// MARK: - File format

/// Parses / serializes the vocabulary markdown file.
///
/// Format (one entry per bullet line):
///
///     # Scribe vocabulary
///     - Kubernetes
///     - cube control -> kubectl
///     - pre a → Priya
///
/// `->` and `→` both separate "heard as" (left) from the replacement
/// (right). Headings, blank lines and `<!-- … -->` comment lines are ignored.
enum VocabularyFile {

    static let header = "# Scribe vocabulary"

    static let explanation = """
    <!-- One entry per line. "- Term" teaches the transcriber a word. "- heard as -> Term" also rewrites that phrase in finished transcripts and dictation (whole words, any case). -->
    """

    static func parse(_ text: String) -> [VocabularyEntry] {
        var result: [VocabularyEntry] = []
        var seen = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("<!--") || line.hasPrefix(">")
                || line == "-" || line == "*" || line == "+" {
                continue
            }
            for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            guard !line.isEmpty else { continue }

            let entry: VocabularyEntry
            if let separator = firstSeparatorRange(in: line) {
                let heard = String(line[line.startIndex..<separator.lowerBound])
                let term = String(line[separator.upperBound...])
                entry = VocabularyEntry(term: term, heardAs: heard)
            } else {
                entry = VocabularyEntry(term: line)
            }
            guard !entry.term.isEmpty, seen.insert(entry.id).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    static func serialize(_ entries: [VocabularyEntry]) -> String {
        var lines = [header, "", explanation, ""]
        for entry in entries where !entry.term.isEmpty {
            if let heard = entry.heardAs {
                lines.append("- \(heard) -> \(entry.term)")
            } else {
                lines.append("- \(entry.term)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Unique terms in list order — what the transcriber receives as
    /// contextual strings.
    static func contextualStrings(for entries: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries where !entry.term.isEmpty {
            if seen.insert(entry.term.lowercased()).inserted { out.append(entry.term) }
        }
        return out
    }

    static func corrections(for entries: [VocabularyEntry]) -> [VocabularyCorrection] {
        entries.compactMap(\.correction)
    }

    /// Range of the earliest `->` or `→` separator in `line`.
    private static func firstSeparatorRange(in line: String) -> Range<String.Index>? {
        let ascii = line.range(of: "->")
        let arrow = line.range(of: "→")
        switch (ascii, arrow) {
        case let (a?, b?): return a.lowerBound <= b.lowerBound ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

// MARK: - Corrector

/// Applies "heard as → replace with" corrections to finalized transcript or
/// dictation text.
///
/// - Whole-word: a phrase only matches when it is not glued to another
///   letter/digit on either side, so `"ai"` never rewrites `"said"`.
///   Adjacent punctuation (`"cube control,"`, `"(cube control)"`) is fine.
/// - Case-insensitive; the replacement is inserted exactly as written.
/// - Multi-word phrases match across any run of whitespace.
/// - Single pass: all rules are compiled into one alternation (longest
///   phrase first), so the output of one rule is never re-matched by another.
struct VocabularyCorrector {

    private let regex: NSRegularExpression?
    /// Normalized "heard as" → replacement.
    private let replacements: [String: String]

    init(corrections: [VocabularyCorrection]) {
        var map: [String: String] = [:]
        for correction in corrections {
            let key = Self.normalize(correction.heardAs)
            let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !replacement.isEmpty, map[key] == nil else { continue }
            map[key] = replacement
        }
        self.replacements = map
        self.regex = Self.makeRegex(for: Array(map.keys))
    }

    init(entries: [VocabularyEntry]) {
        self.init(corrections: VocabularyFile.corrections(for: entries))
    }

    var isEmpty: Bool { replacements.isEmpty }

    func apply(to text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location != NSNotFound, range.location >= cursor else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let matched = ns.substring(with: range)
            out += replacements[Self.normalize(matched)] ?? matched
            cursor = range.location + range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Lowercased with internal whitespace collapsed to single spaces.
    static func normalize(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func makeRegex(for phrases: [String]) -> NSRegularExpression? {
        guard !phrases.isEmpty else { return nil }
        // Longest first so "cube control plane" wins over "cube control".
        let ordered = phrases.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
        }
        let alternation = ordered.map { phrase in
            phrase
                .split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
        }.joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:\(alternation))(?![\\p{L}\\p{N}_])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
