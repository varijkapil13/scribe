import Foundation

/// Speaker naming for the transcript reader: rename "You" / "Remote" for this
/// session and reassign selected segments to a named speaker.
///
/// No diarization: "you" is the mic and "remote" is all system audio. Several
/// remote participants can only be told apart by manually reassigning
/// segments; automatic remote diarization is a future follow-up.
extension TranscriptDetailViewModel {

    /// Reloads this session's speaker names (and the global "you" default).
    func loadSpeakers() {
        speakerResolver = store.speakerResolver(sessionId: session.id)
    }

    /// Display name for a segment's (possibly reassigned) speaker.
    func speakerName(for segment: Segment) -> String {
        speakerResolver.displayName(for: segment)
    }

    /// Speakers offered by the rename sheet and the assign menu.
    var speakerKeys: [String] {
        speakerResolver.availableKeys(in: segments)
    }

    /// Renames `key` for this session. An empty name restores the default.
    func renameSpeaker(key: String, to name: String) {
        do {
            try store.setSpeakerName(name, forKey: key, sessionId: session.id)
            loadSpeakers()
            NotificationCenter.default.post(name: .scribeSessionUpdated, object: session.id)
        } catch {
            Log.storage.error("Failed to rename speaker: \(error.localizedDescription)")
        }
    }

    /// Reassigns the selected segments to `key` (`nil` restores the original
    /// mic/system attribution) and leaves selection mode.
    func assignSelectedSegments(toSpeakerKey key: String?) {
        let ids = Array(selectedSegmentIds)
        guard !ids.isEmpty else { return }
        do {
            try store.setSpeakerOverride(key, forSegmentIds: ids)
            selectedSegmentIds.removeAll()
            isSelecting = false
            loadSegments()
            NotificationCenter.default.post(name: .scribeSessionUpdated, object: session.id)
        } catch {
            Log.storage.error("Failed to reassign segments: \(error.localizedDescription)")
        }
    }

    /// Creates a session speaker called `name` (so it stays listed even with
    /// no segments) and assigns the selection to it.
    func assignSelectedSegments(toNewSpeakerNamed name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = SpeakerNameResolver.key(forNewSpeakerNamed: trimmed)
        if key != SpeakerNameResolver.youKey, key != SpeakerNameResolver.remoteKey {
            try? store.setSpeakerName(trimmed, forKey: key, sessionId: session.id)
        }
        assignSelectedSegments(toSpeakerKey: key)
    }
}
