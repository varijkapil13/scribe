// Scribe/Storage/FTSQuery.swift
import Foundation

/// Shared FTS5 MATCH-expression escaper. Single source of truth for the
/// project's FTS query format — splits raw user input on whitespace, drops
/// non-alphanumeric characters, wraps each surviving token in double quotes
/// (so single quotes / hyphens don't break the parser), and appends `*` for
/// prefix matching.
///
/// Returns an empty string when the input contains nothing matchable; callers
/// should treat that as "no results" rather than passing it to FTS5.
enum FTSQuery {

    static func escape(_ raw: String) -> String {
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token in
                token.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .reduce(into: "") { $0.append(Character($1)) }
            }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
