import Foundation

/// What to do with an editor's pending write when the note's file may have
/// been changed outside Scribe since the editor loaded it.
enum NoteExternalEditPolicy {

    enum Decision: Equatable, Sendable {
        /// Disk still holds the version the editor is based on (or there is
        /// nothing to protect): write normally.
        case write
        /// Disk changed and the editor has no unsaved changes: adopt the
        /// disk version instead of writing.
        case reloadFromDisk
        /// Disk changed *and* the editor has unsaved changes: preserve the
        /// disk version as a conflict copy, then write the in-app version.
        case keepBoth
    }

    /// - Parameters:
    ///   - loaded: fingerprint of the version the editor was loaded from /
    ///     last saved; nil when there was no file (nothing to protect).
    ///   - current: fingerprint of the file now; nil when it no longer
    ///     exists (writing recreates it — nothing on disk to lose).
    ///   - lastWrittenByScribe: fingerprint of the last version Scribe itself
    ///     wrote for the note (e.g. an AI summary inserted by another
    ///     component, which replays the same edit into the open editor).
    ///     Disk matching it is not an *external* edit.
    nonisolated static func decide(
        loaded: NoteFileFingerprint?,
        current: NoteFileFingerprint?,
        lastWrittenByScribe: NoteFileFingerprint? = nil,
        hasUnsavedChanges: Bool
    ) -> Decision {
        guard let loaded, let current else { return .write }
        if isUnchanged(loaded: loaded, current: current) { return .write }
        if let lastWrittenByScribe, current.describesSameContent(as: lastWrittenByScribe) { return .write }
        return hasUnsavedChanges ? .keepBoth : .reloadFromDisk
    }

    /// True when `current` describes the same content as `loaded` (a nil
    /// `loaded` counts as unchanged — nothing was loaded from disk).
    nonisolated static func isUnchanged(loaded: NoteFileFingerprint?, current: NoteFileFingerprint?) -> Bool {
        guard let loaded else { return true }
        guard let current else { return false }
        return loaded.describesSameContent(as: current)
    }
}
