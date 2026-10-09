import Foundation

/// Keeps prompts inside the on-device model's small context window.
///
/// The on-device model has a few thousand tokens of context shared between
/// instructions, prompt and response, so every prompt is built against a
/// conservative *character* budget. Long transcripts are split into chunks on
/// line boundaries, each chunk is condensed by the model, and the condensed
/// notes are merged (repeating if still too long). The model call is injected
/// as a closure so the whole pipeline is testable without Apple Intelligence.
enum TranscriptBudget {

    /// Max transcript characters in a template-summary prompt.
    static let summaryBudget = 6_000
    /// Max transcript characters in an "Enhance notes" prompt (the user's
    /// notes take part of the window).
    static let enhanceTranscriptBudget = 4_000
    /// Max characters of the user's own notes in an "Enhance notes" prompt.
    static let enhanceNotesBudget = 2_500
    /// Max transcript characters in a recipe prompt.
    static let recipeTranscriptBudget = 4_500
    /// Max note characters in a recipe prompt.
    static let recipeNoteBudget = 1_500
    /// Size of each chunk sent for condensing.
    static let chunkSize = 5_000
    /// Upper bound on condense → merge rounds before hard truncation.
    static let maxRounds = 3

    /// `"[00:12] Speaker: text"` lines for a prompt.
    static func formatLines(_ segments: [(speaker: String, text: String, timestamp: String)]) -> [String] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = segment.speaker.trimmingCharacters(in: .whitespaces)
            let prefix = segment.timestamp.isEmpty ? "" : "\(segment.timestamp) "
            return speaker.isEmpty ? "\(prefix)\(text)" : "\(prefix)\(speaker): \(text)"
        }
    }

    /// Packs `lines` into chunks of at most `maxChars` characters (newline
    /// separators included), never splitting a line unless that single line
    /// is itself longer than `maxChars`, in which case it is hard-split.
    static func chunk(lines: [String], maxChars: Int) -> [String] {
        let limit = max(1, maxChars)
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for line in lines {
            if line.count > limit {
                flush()
                var rest = Substring(line)
                while !rest.isEmpty {
                    let piece = rest.prefix(limit)
                    chunks.append(String(piece))
                    rest = rest.dropFirst(piece.count)
                }
                continue
            }
            let added = current.isEmpty ? line.count : current.count + 1 + line.count
            if added > limit {
                flush()
                current = line
            } else {
                current = current.isEmpty ? line : current + "\n" + line
            }
        }
        flush()
        return chunks
    }

    static let omissionMarker = "\n[…]\n"

    /// Keeps the head and tail of `text` within `maxChars` (marker included).
    static func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let room = maxChars - omissionMarker.count
        guard room > 1 else { return String(text.prefix(max(0, maxChars))) }
        let head = room / 2
        let tail = room - head
        return String(text.prefix(head)) + omissionMarker + String(text.suffix(tail))
    }

    /// Fits `lines` into `budget` characters. Returns the joined transcript
    /// unchanged when it already fits; otherwise condenses chunks with
    /// `summarize`, merges the results, and repeats (at most `maxRounds`
    /// times, stopping early when a round makes no progress) before falling
    /// back to `truncate`.
    static func condense(
        lines: [String],
        budget: Int,
        chunkSize: Int = TranscriptBudget.chunkSize,
        maxRounds: Int = TranscriptBudget.maxRounds,
        summarize: @Sendable (String) async throws -> String
    ) async throws -> String {
        let joined = lines.joined(separator: "\n")
        if joined.count <= budget { return joined }

        var currentLines = lines
        var previousSize = joined.count
        var round = 0
        while true {
            round += 1
            let chunks = chunk(lines: currentLines, maxChars: chunkSize)
            var condensed: [String] = []
            for piece in chunks {
                try Task.checkCancellation()
                let result = try await summarize(piece)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty { condensed.append(result) }
            }
            let merged = condensed.joined(separator: "\n\n")
            if merged.count <= budget { return merged }
            if round >= maxRounds || merged.count >= previousSize {
                return truncate(merged, maxChars: budget)
            }
            previousSize = merged.count
            currentLines = condensed
        }
    }
}
