// Scribe/Intelligence/Semantic/SemanticChunker.swift
import Foundation

/// Pure text chunking for the semantic index: splits note bodies and
/// transcripts into passages small enough to embed (and to quote as Ask
/// evidence), plus a stable content hash so unchanged chunks keep their
/// vectors across re-indexing.
enum SemanticChunker {

    /// Target upper bound for one chunk, in characters (~150–200 tokens).
    static let defaultMaxChars = 800

    /// One line of a transcript, as fed to ``chunkTranscript(_:maxChars:)``.
    struct TranscriptLine: Equatable, Sendable {
        var speaker: String
        var text: String
        var startMs: Int
    }

    /// A transcript passage and where it starts.
    struct TranscriptChunk: Equatable, Sendable {
        var text: String
        var startMs: Int
    }

    // MARK: - Notes

    /// Splits a markdown note body into chunks of at most `maxChars`
    /// characters. Paragraphs (blank-line separated) are packed greedily;
    /// a paragraph longer than `maxChars` is split at sentence boundaries,
    /// then at word boundaries. Front matter, fenced-code markers and
    /// heading/list markup are dropped so the embedding sees prose.
    nonisolated static func chunkNote(body: String, maxChars: Int = defaultMaxChars) -> [String] {
        let limit = max(maxChars, 40)
        let paragraphs = paragraphs(of: stripFrontMatter(body))
        var pieces: [String] = []
        for paragraph in paragraphs {
            if paragraph.count <= limit {
                pieces.append(paragraph)
            } else {
                pieces += splitLong(paragraph, maxChars: limit)
            }
        }
        return pack(pieces, maxChars: limit, separator: "\n\n")
    }

    // MARK: - Transcripts

    /// Groups consecutive transcript lines into passages of at most
    /// `maxChars` characters, each rendered as `Speaker: text` lines and
    /// tagged with its first line's start time. A single over-long line is
    /// split on its own.
    nonisolated static func chunkTranscript(_ lines: [TranscriptLine], maxChars: Int = defaultMaxChars) -> [TranscriptChunk] {
        let limit = max(maxChars, 40)
        var out: [TranscriptChunk] = []
        var current = ""
        var currentStart = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(TranscriptChunk(text: trimmed, startMs: currentStart)) }
            current = ""
        }

        for line in lines {
            let text = collapseWhitespace(line.text)
            guard !text.isEmpty else { continue }
            let speaker = line.speaker.trimmingCharacters(in: .whitespaces)
            let rendered = speaker.isEmpty ? text : "\(speaker): \(text)"

            if rendered.count > limit {
                flush()
                for part in splitLong(rendered, maxChars: limit) {
                    out.append(TranscriptChunk(text: part, startMs: line.startMs))
                }
                continue
            }
            if current.isEmpty {
                current = rendered
                currentStart = line.startMs
            } else if current.count + 1 + rendered.count <= limit {
                current += "\n" + rendered
            } else {
                flush()
                current = rendered
                currentStart = line.startMs
            }
        }
        flush()
        return out
    }

    // MARK: - Hash

    /// Stable 64-bit FNV-1a hash of the UTF-8 bytes, as 16 hex digits.
    /// (`String.hashValue` is randomly seeded per launch, so unusable here.)
    nonisolated static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    // MARK: - Helpers

    /// Removes a leading `---` … `---` YAML block.
    nonisolated static func stripFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        for index in lines.indices.dropFirst() where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(index + 1)...].joined(separator: "\n")
        }
        return text
    }

    /// Blank-line separated paragraphs with markdown markup removed.
    nonisolated static func paragraphs(of text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        func flush() {
            let joined = collapseWhitespace(current.joined(separator: " "))
            if !joined.isEmpty { out.append(joined) }
            current = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            guard let line = cleanMarkdownLine(rawLine) else {
                flush()
                continue
            }
            guard !line.isEmpty else { continue }
            // A heading is its own paragraph (packing may still join it
            // with the text that follows).
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                flush()
                current.append(line)
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return out
    }

    /// The prose of one markdown line: nil for a paragraph break (blank
    /// line, code fence, horizontal rule), otherwise the line without
    /// heading / list / quote / checkbox markers.
    nonisolated static func cleanMarkdownLine(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("~~~") { return nil }
        if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 { return nil }
        while line.hasPrefix("#") { line.removeFirst() }
        while line.hasPrefix(">") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
            line.removeFirst(marker.count)
            break
        }
        // "1. item"
        if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber),
           line.startIndex != dot {
            let after = line.index(after: dot)
            if after < line.endIndex, line[after] == " " {
                line = String(line[line.index(after: after)...])
            }
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Splits text longer than `maxChars` at sentence ends, falling back to
    /// word boundaries (and hard cuts for a single enormous word).
    nonisolated static func splitLong(_ text: String, maxChars: Int) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "?" || character == "!" || character == "\n" {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var pieces: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxChars {
                pieces.append(trimmed)
            } else {
                pieces += splitWords(trimmed, maxChars: maxChars)
            }
        }
        return pack(pieces, maxChars: maxChars, separator: " ")
    }

    nonisolated static func splitWords(_ text: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            var piece = String(word)
            while piece.count > maxChars {
                if !current.isEmpty { out.append(current); current = "" }
                out.append(String(piece.prefix(maxChars)))
                piece = String(piece.dropFirst(maxChars))
            }
            if piece.isEmpty { continue }
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= maxChars {
                current += " " + piece
            } else {
                out.append(current)
                current = piece
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Greedily joins pieces (each already ≤ `maxChars`) into chunks of at
    /// most `maxChars` characters.
    nonisolated static func pack(_ pieces: [String], maxChars: Int, separator: String) -> [String] {
        var out: [String] = []
        var current = ""
        for piece in pieces where !piece.isEmpty {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= maxChars {
                current += separator + piece
            } else {
                out.append(current)
                current = piece
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
