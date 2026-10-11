import Foundation

// MARK: - Persisted diarization jobs (portable)
//
// An iPhone / iPad diarization job can wait hours for the charger (and the
// app can be killed in between), so each one is a small JSON file in
// Application Support until it ran. Foundation only; covered by tests.

/// One finished recording waiting for speaker diarization.
struct MobileDiarizationJob: Codable, Equatable, Sendable {

    /// A raw recognizer result (finer timing than the stored, coalesced
    /// segments); see `DiarizedSegmentRebuilder.Piece`.
    struct Piece: Codable, Equatable, Sendable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    var sessionId: String
    /// The folder holding the audio.
    var audioDirectoryPath: String
    /// The file to diarize inside it (`mic.m4a` for live recordings,
    /// `system.m4a` for imports).
    var audioFileName: String
    /// True when the audio was only kept for diarization (Keep audio off) and
    /// is deleted once the job is done.
    var isScratch: Bool
    /// Speaker keys of the segments to split (e.g. "In person").
    var speakerKeys: [String]
    var pieces: [Piece]
    var createdAt: Date
    /// Failed runs so far (deferrals don't count).
    var failureCount: Int

    nonisolated init(
        sessionId: String,
        audioDirectoryPath: String,
        audioFileName: String,
        isScratch: Bool,
        speakerKeys: [String],
        pieces: [Piece],
        createdAt: Date,
        failureCount: Int
    ) {
        self.sessionId = sessionId
        self.audioDirectoryPath = audioDirectoryPath
        self.audioFileName = audioFileName
        self.isScratch = isScratch
        self.speakerKeys = speakerKeys
        self.pieces = pieces
        self.createdAt = createdAt
        self.failureCount = failureCount
    }

    nonisolated var audioDirectory: URL {
        URL(fileURLWithPath: audioDirectoryPath, isDirectory: true)
    }

    nonisolated var audioFileURL: URL {
        audioDirectory.appendingPathComponent(audioFileName, isDirectory: false)
    }

    /// The pieces in the rebuilder's shape.
    nonisolated var rebuilderPieces: [DiarizedSegmentRebuilder.Piece] {
        pieces.map { DiarizedSegmentRebuilder.Piece(startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }
    }

    /// A job is dropped after this many failed runs.
    nonisolated static let maximumFailures = 3
}

/// The on-disk queue: `<directory>/<session id>.json`.
struct MobileDiarizationQueue: Sendable {
    let directory: URL

    nonisolated init(directory: URL) {
        self.directory = directory
    }

    /// `<Application Support>/Scribe/DiarizationQueue`.
    nonisolated static func defaultDirectory(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("DiarizationQueue", isDirectory: true)
    }

    /// `<Application Support>/Scribe/DiarizationAudio/<session id>` — audio
    /// recorded only for diarization (lives outside the temporary folder so
    /// it survives until a background task runs).
    nonisolated static func scratchAudioDirectory(applicationSupport: URL, sessionId: String) -> URL {
        applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("DiarizationAudio", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    nonisolated func fileURL(for sessionId: String) -> URL {
        directory.appendingPathComponent(Self.safeFileName(sessionId) + ".json", isDirectory: false)
    }

    /// Adds or replaces the job for its session.
    nonisolated func save(_ job: MobileDiarizationJob) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(job)
        try data.write(to: fileURL(for: job.sessionId), options: .atomic)
    }

    /// Every readable job, oldest first. Unreadable files are removed.
    nonisolated func pending() -> [MobileDiarizationJob] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        var jobs: [MobileDiarizationJob] = []
        for entry in entries where entry.pathExtension == "json" {
            if let data = try? Data(contentsOf: entry),
               let job = try? decoder.decode(MobileDiarizationJob.self, from: data) {
                jobs.append(job)
            } else {
                try? fileManager.removeItem(at: entry)
            }
        }
        return jobs.sorted { ($0.createdAt, $0.sessionId) < ($1.createdAt, $1.sessionId) }
    }

    nonisolated func job(for sessionId: String) -> MobileDiarizationJob? {
        pending().first { $0.sessionId == sessionId }
    }

    nonisolated func remove(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
    }

    /// Session ids are UUIDs; anything else is reduced to a safe file name.
    nonisolated static func safeFileName(_ sessionId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(sessionId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }
}

extension MobileDiarizationJob {

    /// Shifts turns (timed from the start of the diarized file) onto the
    /// session clock the segments use, via the folder's `timing.json` when
    /// there is one (iPhone recordings start their file at 0).
    nonisolated func turnsOnSessionClock(
        _ turns: [DiarizedSegmentRebuilder.Turn],
        timing: SessionAudioTiming?
    ) -> [DiarizedSegmentRebuilder.Turn] {
        guard let timing else { return turns }
        let offset = audioFileName == SessionAudioStorage.systemFileName
            ? timing.systemStartOffsetSeconds
            : timing.micStartOffsetSeconds
        guard offset != 0 else { return turns }
        return turns.map {
            DiarizedSegmentRebuilder.Turn(speakerId: $0.speakerId, start: $0.start + offset, end: $0.end + offset)
        }
    }
}
