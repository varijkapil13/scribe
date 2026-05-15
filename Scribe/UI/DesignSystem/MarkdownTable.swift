// Scribe/UI/DesignSystem/MarkdownTable.swift
import Foundation

/// A detected markdown pipe table inside a source body. Line indexes are
/// 0-based into the array returned by `source.components(separatedBy: "\n")`.
struct DetectedMarkdownTable: Equatable {
    let headerRow: Int
    let separatorRow: Int
    let bodyRows: [Int]
    let columnCount: Int
    /// Max content character count per column across header + body rows.
    let columnWidths: [Int]
}

enum MarkdownTable {

    /// Returns every detected table block in source order.
    static func detect(in source: String) -> [DetectedMarkdownTable] {
        let lines = source.components(separatedBy: "\n")
        var result: [DetectedMarkdownTable] = []

        var i = 0
        while i < lines.count - 1 {
            let header = lines[i]
            let separator = lines[i + 1]
            guard isPipeRow(header), isSeparator(separator) else {
                i += 1
                continue
            }
            let headerCells = cells(in: header)
            let columnCount = headerCells.count

            var bodyRows: [Int] = []
            var j = i + 2
            while j < lines.count, isPipeRow(lines[j]), cells(in: lines[j]).count == columnCount {
                bodyRows.append(j)
                j += 1
            }

            // Column widths: max of (header cell text length, max body cell length per column).
            var widths = headerCells.map { $0.count }
            for row in bodyRows {
                let bodyCells = cells(in: lines[row])
                for (col, txt) in bodyCells.enumerated() where col < widths.count {
                    widths[col] = max(widths[col], txt.count)
                }
            }

            result.append(DetectedMarkdownTable(
                headerRow: i,
                separatorRow: i + 1,
                bodyRows: bodyRows,
                columnCount: columnCount,
                columnWidths: widths
            ))
            i = j
        }
        return result
    }

    private static func isPipeRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.filter({ $0 == "|" }).count >= 2
    }

    private static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return false }
        let interior = trimmed.dropFirst().dropLast()
        return interior.allSatisfy { c in
            c == "-" || c == ":" || c == "|" || c == " " || c == "\t"
        } && interior.contains("-")
    }

    private static func cells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let inner = trimmed.dropFirst().dropLast()
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
