// Scribe/UI/DesignSystem/ChecklistToggle.swift
import Foundation

/// Pure helper for toggling a markdown checklist item's `[ ]` ↔ `[x]` state.
/// Operates on the line that contains the given character location.
enum ChecklistToggle {

    /// Returns a copy of `source` with the checklist marker on the line
    /// containing `atLocation` flipped between `[ ]` and `[x]`. Capital `X`
    /// is treated as checked and normalised to lowercase `x` when toggled.
    /// Returns `nil` when the line has no checkbox marker.
    static func toggle(source: String, atLocation: Int) -> String? {
        let nsSource = source as NSString
        guard atLocation >= 0, atLocation <= nsSource.length else { return nil }
        let lineRange = nsSource.lineRange(for: NSRange(location: atLocation, length: 0))
        let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)

        guard let markerRange = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else {
            return nil
        }
        let marker = String(line[markerRange])
        let toggled = (marker == "[ ]") ? "[x]" : "[ ]"
        let newLine = line.replacingCharacters(in: markerRange, with: toggled)
        // Preserve any trailing newline from the original line range.
        let original = nsSource.substring(with: lineRange)
        let suffix = String(original.suffix(while: { $0.isNewline }))
        let result = nsSource.replacingCharacters(in: lineRange, with: newLine + suffix)
        return result
    }
}

private extension String {
    /// Returns the suffix where every character matches `predicate`.
    func suffix(while predicate: (Character) -> Bool) -> String {
        var idx = endIndex
        while idx > startIndex {
            let prev = index(before: idx)
            if predicate(self[prev]) {
                idx = prev
            } else {
                break
            }
        }
        return String(self[idx...])
    }
}
