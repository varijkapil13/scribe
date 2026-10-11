import Foundation

/// One page of remote changes in the `Meetings` zone, already decoded.
struct MeetingCloudChangeBatch: Sendable {
    var sessions: [MeetingSessionSnapshot]
    /// Transcripts that changed, by session id.
    var transcripts: [String: MeetingTranscriptPayload]
    /// `MeetingSession` records removed from the zone outright (not
    /// tombstoned) — e.g. the user cleared iCloud data for Scribe.
    var removedSessionIds: [String]
    /// Opaque cursor to persist and pass to the next fetch.
    var token: Data?
    var moreComing: Bool

    init(
        sessions: [MeetingSessionSnapshot] = [],
        transcripts: [String: MeetingTranscriptPayload] = [:],
        removedSessionIds: [String] = [],
        token: Data? = nil,
        moreComing: Bool = false
    ) {
        self.sessions = sessions
        self.transcripts = transcripts
        self.removedSessionIds = removedSessionIds
        self.token = token
        self.moreComing = moreComing
    }
}

/// A local audio file to upload.
struct MeetingAudioUpload: Sendable {
    var info: MeetingAudioFileInfo
    var fileURL: URL
}

enum MeetingCloudServiceError: Error, Equatable {
    /// The change token is no longer valid: refetch from scratch.
    case changeTokenExpired
    /// The zone was deleted (e.g. the user cleared iCloud data): recreate it.
    case zoneMissing
    /// The record (audio file) isn't in iCloud.
    case recordMissing
}

/// The CloudKit side of meeting sync, abstracted so the engine is unit-tested
/// against an in-memory fake. `MeetingCloudKitService` is the live one.
protocol MeetingCloudServicing: Sendable {
    /// Creates the `Meetings` zone if needed.
    func ensureZone() async throws
    /// One page of changes since `token` (nil = everything). Audio assets are
    /// NOT downloaded here — only on demand via `downloadAudio`.
    func fetchChanges(since token: Data?) async throws -> MeetingCloudChangeBatch
    /// The current transcript of a session, nil when there is none.
    func fetchTranscript(sessionId: String) async throws -> MeetingTranscriptPayload?
    /// Saves the session record (and, when non-nil, its transcript). Returns
    /// whether everything given was saved.
    func saveSession(_ snapshot: MeetingSessionSnapshot, transcript: MeetingTranscriptPayload?) async throws -> Bool
    /// Uploads audio files; returns the ones that were saved.
    func uploadAudio(sessionId: String, files: [MeetingAudioUpload]) async throws -> [MeetingAudioFileInfo]
    /// Removes a deleted session's transcript and audio records.
    func deleteSessionPayloads(sessionId: String) async throws
    /// Downloads one audio file of a session to `destination` (replacing it).
    func downloadAudio(sessionId: String, fileName: String, to destination: URL) async throws
}
