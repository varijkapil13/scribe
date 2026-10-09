import Foundation

/// Pure text shaping for dictation: stitches finalized speech segments into
/// one string and applies the cheap, deterministic cleanup that runs even
/// when Apple Intelligence isn't available (filler words, spacing, a leading
/// capital). Kept free of Speech/AppKit so CI pins it down.
enum DictationTextFormatter {

    /// Standalone hesitation sounds. Deliberately conservative: only tokens
    /// that are never meaningful words ("like", "so" and "well" are left
    /// alone; the optional AI cleanup can handle those in context).
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm"]

    /// Joins segments with single spaces, trimming each.
    static func join(_ segments: [String]) -> String {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes filler tokens (with any trailing comma), collapses whitespace,
    /// tidies space-before-punctuation, and capitalizes the first letter.
    static func clean(_ text: String) -> String {
        var words: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let bare = token
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.…?!"))
                .lowercased()
            if fillers.contains(bare) {
                // "…we ship, um." ends a sentence: move the terminator onto
                // the previous word unless it already has one.
                if let mark = token.last, ".?!".contains(mark),
                   let last = words.last, !(last.last.map { ".?!".contains($0) } ?? false) {
                    words[words.count - 1] = last.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + String(mark)
                }
                continue
            }
            words.append(String(token))
        }
        var result = words.joined(separator: " ")
        for mark in [",", ".", "?", "!", ";", ":"] {
            result = result.replacingOccurrences(of: " " + mark, with: mark)
        }
        guard let first = result.first else { return "" }
        return first.uppercased() + result.dropFirst()
    }

    /// Guards the Apple Intelligence cleanup: accept the model's output only
    /// if it looks like an *edit* of what was said (similar length), not an
    /// answer to it or a refusal. A cleanup only removes fillers and adds
    /// punctuation, so it should never grow much or shrink by half.
    static func isPlausibleEdit(of original: String, _ edited: String) -> Bool {
        let before = original.trimmingCharacters(in: .whitespacesAndNewlines).count
        let after = edited.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard before > 0, after > 0 else { return false }
        return Double(after) >= Double(before) * 0.5 && after <= before + before / 4 + 12
    }

    /// The text to insert: joined segments, optionally cleaned.
    static func finalText(segments: [String], removeFillers: Bool) -> String {
        let joined = join(segments)
        return removeFillers ? clean(joined) : joined
    }
}
