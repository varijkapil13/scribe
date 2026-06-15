//
//  SwiftPMEntryShim.swift
//  Scribe
//
//  SwiftPM-ONLY entry point. Compiled only by the `swift test` build of the
//  SwiftPM `Scribe` executable target — NOT by the xcodebuild app (project.yml
//  excludes it there, where the real `@main ScribeApp` provides the entry).
//
//  Why this exists:
//  The native editor (CodeEditSourceEditor) can't be pulled into the SwiftPM
//  graph (its CodeEditSymbols target fails to synthesize `Bundle.module` under
//  `swift test`). So every SwiftUI view that transitively references the
//  editor-backed `CodeEditNoteTextView` is excluded from the SwiftPM target —
//  including `ScribeApp.swift`, which owns the app's real `@main`. Excluding
//  the real entry point leaves the executable target with no `main`, which
//  fails to link.
//
//  This shim restores a trivial entry point for the SwiftPM build alone, so
//  `swift test` (the logic-test job) can compile + link the target and run its
//  tests. It is never part of the shipping app.
//
//  See the exclusion-boundary comment in Package.swift.
//

#if SCRIBE_SPM_ENTRY
import Foundation

/// Minimal SwiftPM executable entry. Does nothing — the logic tests never run
/// this `main`; they `@testable import Scribe` and exercise the types directly.
@main
enum SwiftPMEntry {
    static func main() {
        // Intentionally empty. The xcodebuild app uses `ScribeApp` (`@main`)
        // instead; this entry only satisfies the SwiftPM executable linker for
        // the `swift test` job.
    }
}
#endif
