// Scribe/Storage/FTSQuery.swift
import Foundation

/// Shared FTS5 MATCH-expression escaper. Single source of truth for the
/// project's FTS query format — splits raw user input on every non-alphanumeric
/// character, wraps each surviving token in double quotes (so single quotes /
/// hyphens don't break the parser), and appends `*` for prefix matching.
///
/// Splitting on punctuation — rather than deleting it from inside a token —
/// mirrors FTS5's default unicode61 tokenizer, which treats hyphens,
/// apostrophes, underscores and periods as token boundaries. That's what makes
/// a query like "co-founder" become `"co"* "founder"*` (which matches indexed
/// "co-founder") instead of the unmatchable `"cofounder"*`.
///
/// Returns an empty string when the input contains nothing matchable; callers
/// should treat that as "no results" rather than passing it to FTS5.
enum FTSQuery {

    static func escape(_ raw: String) -> String {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
