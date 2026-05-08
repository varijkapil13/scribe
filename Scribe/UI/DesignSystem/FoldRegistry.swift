// Scribe/UI/DesignSystem/FoldRegistry.swift
import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Carries the original fence text (incl. ```...``` markers) on a fold attachment glyph.
    static let foldSource = NSAttributedString.Key("scribe.foldSource")
    /// UUID linking a fold attachment to a `FoldEntry` so the hover overlay can identify it.
    static let foldId = NSAttributedString.Key("scribe.foldId")
}

struct FoldEntry: Equatable {
    let id: UUID
    /// Index of the attachment character in display coords.
    let displayLocation: Int
    /// Index where the fence text begins in source coords.
    let sourceLocation: Int
    /// Length of the fence text in source coords (UTF-16 / NSString units).
    let sourceLength: Int
}

enum FoldRegistry {

    /// Translate a display index to a source index using the registry.
    /// Folds that precede the display index expand by `sourceLength - 1`.
    /// A display index that lands exactly on a fold attachment maps to the fold's source start.
    static func sourceLocation(forDisplay loc: Int, registry: [FoldEntry]) -> Int {
        var src = loc
        for fold in registry where fold.displayLocation < loc {
            src += fold.sourceLength - 1
        }
        return src
    }

    /// Translate a source index to a display index using the registry.
    /// A source index inside any fold's range clamps to that fold's display location
    /// (which, on the next reformat, will cause the fold to expand and the cursor to land there).
    static func displayLocation(forSource loc: Int, registry: [FoldEntry]) -> Int {
        for fold in registry where loc >= fold.sourceLocation && loc < fold.sourceLocation + fold.sourceLength {
            return fold.displayLocation
        }
        var disp = loc
        for fold in registry where fold.sourceLocation + fold.sourceLength <= loc {
            disp -= fold.sourceLength - 1
        }
        return disp
    }

    /// Walks an NSAttributedString and returns:
    ///  - `source`: the reconstructed markdown source.
    ///  - `registry`: every `.foldSource`/`.foldId`-tagged run, in display order.
    static func decompose(_ attributed: NSAttributedString) -> (source: String, registry: [FoldEntry]) {
        var source = ""
        var registry: [FoldEntry] = []
        let full = NSRange(location: 0, length: attributed.length)
        let plainNS = attributed.string as NSString

        attributed.enumerateAttribute(.foldSource, in: full) { value, range, _ in
            if let foldSrc = value as? String {
                let id = (attributed.attribute(.foldId, at: range.location, effectiveRange: nil) as? UUID) ?? UUID()
                registry.append(FoldEntry(
                    id: id,
                    displayLocation: range.location,
                    sourceLocation: (source as NSString).length,
                    sourceLength: (foldSrc as NSString).length
                ))
                source += foldSrc
            } else {
                source += plainNS.substring(with: range)
            }
        }
        return (source, registry)
    }
}
