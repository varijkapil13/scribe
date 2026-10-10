import Foundation

// MARK: - Retained session audio

extension AppState {

    /// The folder a new session's audio should be written to, or nil when
    /// "Retain raw audio recordings" is off. Pure apart from reading
    /// `defaults`, so it's testable.
    nonisolated static func audioDirectoryForNewSession(
        sessionId: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        guard SessionAudioStorage.isRetentionEnabled(defaults: defaults) else { return nil }
        return SessionAudioStorage.directory(
            forSessionId: sessionId,
            root: SessionAudioStorage.defaultRoot(defaults: defaults)
        )
    }

    /// Launch-time audio housekeeping: applies the retention policy and
    /// removes audio folders whose session no longer exists. Runs off the
    /// main actor; failures are logged only.
    nonisolated static func runAudioHousekeeping(store: TranscriptStore) {
        let policy = AudioRetentionPolicy.current()
        let root = SessionAudioStorage.defaultRoot()
        Task.detached(priority: .utility) {
            do {
                let result = try store.runAudioHousekeeping(policy: policy, root: root)
                if result.expired > 0 || result.orphans > 0 {
                    Log.app.info("Audio housekeeping removed \(result.expired) expired and \(result.orphans) orphaned recording(s).")
                }
            } catch {
                Log.app.error("Audio housekeeping failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
