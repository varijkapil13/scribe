import Foundation

/// Encoder + decoder for the flat YAML subset Scribe uses in note
/// frontmatter blocks. Deliberately limited (no nesting, no anchors, no
/// multi-line scalars) so the parser is small, deterministic, and easy to
/// reason about. Obsidian's reader handles this subset fine; anything
/// fancier risks lossy round-trips when an external editor touches the
/// file.
///
/// Wire format example:
///
/// ```
/// ---
/// id: 9e3b8a1f-1f6e-4f3c-9d4a-2b1c6c7e1234
/// title: My Note Title
/// created: 2026-05-18T10:00:00.000Z
/// updated: 2026-05-18T11:00:00.000Z
/// notebookId:
/// tags: [foo, bar]
/// isDailyNote: false
/// dailyDate:
/// ---
/// ```
///
/// Empty values are emitted as `key: ` (a bare key with empty value)
/// rather than `null` or `~` so the file remains friendly to humans and
/// other markdown tools.
enum NoteFrontmatterCodec {

    /// Marker line that opens *and* closes the frontmatter block.
    static let delimiter = "---"

    /// Keys the codec models with typed fields. Any other key parsed from a
    /// file is preserved verbatim in `NoteFrontmatter.extra` so external
    /// tools' metadata (and Scribe's own future `cover:`/`icon:`/`font:`)
    /// survives a round-trip instead of being dropped on the next save.
    static let knownKeys: Set<String> = [
        "id", "title", "created", "updated", "notebookId", "tags",
        "isDailyNote", "dailyDate",
    ]

    // MARK: - Encode

    /// Renders `(id, frontmatter)` as a frontmatter block. Always ends with
    /// a single newline after the closing delimiter so the body starts on
    /// the line directly after.
    static func encode(id: String, frontmatter f: NoteFrontmatter) -> String {
        var out: [String] = []
        out.append(delimiter)
        out.append("id: \(id)")
        out.append("title: \(escapeScalar(f.title))")
        out.append("created: \(isoFormatter.string(from: f.createdAt))")
        out.append("updated: \(isoFormatter.string(from: f.updatedAt))")
        out.append("notebookId: \(f.notebookId ?? "")")
        out.append("tags: \(encodeTags(f.tags))")
        out.append("isDailyNote: \(f.isDailyNote ? "true" : "false")")
        if let dailyDate = f.dailyDate {
            out.append("dailyDate: \(dateOnlyFormatter.string(from: dailyDate))")
        } else {
            out.append("dailyDate:")
        }
        // Re-emit unknown keys verbatim, after the typed block, so a file
        // touched by another tool (or carrying Scribe's additive metadata)
        // round-trips losslessly. Values were captured already-encoded on
        // decode, so they are emitted as-is.
        for entry in f.extra where !knownKeys.contains(entry.key) {
            out.append("\(entry.key): \(entry.value)")
        }
        out.append(delimiter)
        return out.joined(separator: "\n") + "\n"
    }

    /// Combines `encode(id:frontmatter:)` with the body, producing the full
    /// file contents. Ensures exactly one blank line between the
    /// frontmatter and the body (no leading newline soup).
    static func encodeFile(id: String, frontmatter: NoteFrontmatter, body: String) -> String {
        let header = encode(id: id, frontmatter: frontmatter)
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        if trimmedBody.isEmpty {
            return header
        }
        return header + "\n" + trimmedBody + "\n"
    }

    // MARK: - Decode

    /// Splits the file contents into `(id, frontmatter, body)`. Tolerates
    /// missing or malformed frontmatter — in those cases, returns a
    /// best-effort frontmatter (using `fallbackTitle`, current time) and
    /// the full file contents as the body, so an external app dropping a
    /// raw `.md` file into the vault still surfaces something readable.
    ///
    /// - Parameters:
    ///   - contents: Full file contents.
    ///   - fallbackTitle: Title to use when frontmatter is missing or has
    ///     no `title` key — typically the filename minus extension.
    ///   - fallbackId: ID to use when frontmatter is missing or has no
    ///     `id` key — caller supplies a freshly generated UUID so reads
    ///     remain deterministic.
    static func decodeFile(
        contents: String,
        fallbackTitle: String,
        fallbackId: String
    ) -> (id: String, frontmatter: NoteFrontmatter, body: String) {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let (headerLines, bodyStartIndex) = extractFrontmatterBlock(lines: lines) else {
            // No frontmatter — use defaults, treat the entire file as body.
            let now = Date()
            return (
                id: fallbackId,
                frontmatter: NoteFrontmatter(
                    title: fallbackTitle,
                    createdAt: now,
                    updatedAt: now
                ),
                body: contents.trimmingCharacters(in: .newlines)
            )
        }

        let parsed = parseHeaderLines(headerLines)
        let id = parsed["id"].nonEmpty ?? fallbackId
        let now = Date()
        let frontmatter = NoteFrontmatter(
            title: parsed["title"].nonEmpty.map(unescapeScalar) ?? fallbackTitle,
            createdAt: parsed["created"].flatMap { isoFormatter.date(from: $0) } ?? now,
            updatedAt: parsed["updated"].flatMap { isoFormatter.date(from: $0) } ?? now,
            notebookId: parsed["notebookId"].nonEmpty,
            tags: parsed["tags"].map(decodeTags) ?? [],
            isDailyNote: parsed["isDailyNote"]?.lowercased() == "true",
            dailyDate: parsed["dailyDate"].flatMap { dateOnlyFormatter.date(from: $0) },
            extra: parseExtraEntries(headerLines)
        )

        let bodyLines = lines.suffix(from: bodyStartIndex)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (id: id, frontmatter: frontmatter, body: body)
    }

    // MARK: - Helpers

    /// Returns the lines *inside* the frontmatter block (without the
    /// delimiter lines) plus the index in `lines` where the body begins,
    /// or `nil` if no well-formed block is present. Requires the very
    /// first line to be `---`; trailing whitespace on delimiter lines is
    /// tolerated so a CRLF-saved file still parses.
    private static func extractFrontmatterBlock(lines: [String]) -> (headerLines: [String], bodyStartIndex: Int)? {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == delimiter else {
            return nil
        }
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == delimiter {
                let headerLines = Array(lines[1..<i])
                let bodyStart = min(i + 1, lines.count)
                return (headerLines, bodyStart)
            }
        }
        return nil
    }

    private static func parseHeaderLines(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            guard let (key, value) = splitKeyValue(line) else { continue }
            out[key] = value
        }
        return out
    }

    /// Unknown keys, in file order, with non-empty verbatim values. Drives
    /// `NoteFrontmatter.extra` so a re-encode preserves anything the typed
    /// fields don't model (external tools' metadata; Scribe's `cover:` etc.).
    private static func parseExtraEntries(_ lines: [String]) -> [FrontmatterEntry] {
        var out: [FrontmatterEntry] = []
        for line in lines {
            guard let (key, value) = splitKeyValue(line) else { continue }
            guard !knownKeys.contains(key), !value.isEmpty else { continue }
            out.append(FrontmatterEntry(key: key, value: value))
        }
        return out
    }

    private static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func encodeTags(_ tags: [String]) -> String {
        guard !tags.isEmpty else { return "[]" }
        let escaped = tags.map(escapeScalar).joined(separator: ", ")
        return "[\(escaped)]"
    }

    private static func decodeTags(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map(unescapeScalar)
            .filter { !$0.isEmpty }
    }

    /// Quotes a scalar if it contains characters that would confuse the
    /// minimal parser (commas, colons, `#`, leading/trailing whitespace).
    /// Otherwise emits bare. Symmetric with `unescapeScalar`.
    private static func escapeScalar(_ s: String) -> String {
        let needsQuotes = s.contains(",")
            || s.contains(":")
            || s.contains("#")
            || s.contains("\"")
            || s.contains("[") || s.contains("]")
            || s != s.trimmingCharacters(in: .whitespaces)
        guard needsQuotes else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unescapeScalar(_ s: String) -> String {
        guard s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 else { return s }
        let inner = String(s.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - Date formatters

    // Both formatters are thread-safe in their read-only configuration but
    // the Foundation declarations don't carry Sendable conformance. Marked
    // unsafe to silence Swift 6 strict-concurrency warnings — consistent
    // with the rest of the storage layer.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

private extension Optional where Wrapped == String {
    /// Collapses `nil` and empty into `nil` so callers can default with a
    /// single `?? fallback` step.
    var nonEmpty: String? {
        guard let v = self, !v.isEmpty else { return nil }
        return v
    }
}
