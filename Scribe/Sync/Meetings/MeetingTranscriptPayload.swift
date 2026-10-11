import CryptoKit
import Foundation

/// A session's whole transcript as one value — the content of the
/// `MeetingTranscript` record's CKAsset.
///
/// Entries carry an `ordinal` (their position in start-time order) instead of
/// the local Int64 segment ids, which mean nothing on another device.
/// Importing replaces the session's segments with these entries, so pulling
/// the same transcript twice never duplicates anything.
struct MeetingTranscriptPayload: Codable, Equatable, Sendable {

    nonisolated static let currentVersion = 1

    struct Entry: Codable, Equatable, Sendable {
        var ordinal: Int
        var startMs: Int
        var endMs: Int
        /// Source speaker label ("you", "remote", …).
        var speaker: String
        var text: String
        /// Manual / diarization reassignment (`segments.speakerOverride`).
        var speakerOverride: String?
    }

    var version: Int
    var sessionId: String
    var entries: [Entry]

    init(version: Int = MeetingTranscriptPayload.currentVersion, sessionId: String, entries: [Entry]) {
        self.version = version
        self.sessionId = sessionId
        self.entries = entries
    }

    /// Builds the payload from local segments: ordered by start time, then by
    /// local row id (insertion order) for equal starts, numbered 0…n-1.
    nonisolated static func make(sessionId: String, segments: [Segment]) -> MeetingTranscriptPayload {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return (lhs.id ?? Int64.max) < (rhs.id ?? Int64.max)
        }
        let entries = ordered.enumerated().map { index, segment in
            Entry(
                ordinal: index,
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: segment.speaker,
                text: segment.text,
                speakerOverride: segment.speakerOverride
            )
        }
        return MeetingTranscriptPayload(sessionId: sessionId, entries: entries)
    }

    /// The entries as unsaved segments of `sessionId`, in ordinal order.
    nonisolated func segments(forSessionId sessionId: String) -> [Segment] {
        entries.sorted { $0.ordinal < $1.ordinal }.map { entry in
            Segment(
                sessionId: sessionId,
                startMs: entry.startMs,
                endMs: entry.endMs,
                speaker: entry.speaker,
                text: entry.text,
                speakerOverride: entry.speakerOverride
            )
        }
    }
}

enum MeetingTranscriptCodecError: Error, Equatable {
    case notATranscript
    case unsupportedVersion(Int)
}

/// Wire encoding of `MeetingTranscriptPayload`: a 4-byte magic ("SMT1")
/// followed by zlib-compressed canonical JSON. Pure, so it's unit-tested.
enum MeetingTranscriptCodec {

    nonisolated static let magic: [UInt8] = Array("SMT1".utf8)

    /// Canonical JSON (sorted keys) — also the input of `hash`.
    nonisolated static func canonicalJSON(_ payload: MeetingTranscriptPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    nonisolated static func encode(_ payload: MeetingTranscriptPayload) throws -> Data {
        let json = try canonicalJSON(payload)
        let compressed = try compress(json)
        var data = Data(magic)
        data.append(compressed)
        return data
    }

    nonisolated static func decode(_ data: Data) throws -> MeetingTranscriptPayload {
        guard data.count >= magic.count, Array(data.prefix(magic.count)) == magic else {
            throw MeetingTranscriptCodecError.notATranscript
        }
        let json = try decompress(Data(data.dropFirst(magic.count)))
        let payload = try JSONDecoder().decode(MeetingTranscriptPayload.self, from: json)
        guard payload.version <= MeetingTranscriptPayload.currentVersion else {
            throw MeetingTranscriptCodecError.unsupportedVersion(payload.version)
        }
        return payload
    }

    /// SHA-256 (hex) of the canonical JSON: equal transcripts hash equally on
    /// every device, so an unchanged transcript is never re-uploaded or
    /// re-imported.
    nonisolated static func hash(_ payload: MeetingTranscriptPayload) -> String {
        let json = (try? canonicalJSON(payload)) ?? Data()
        let digest = SHA256.hash(data: json)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Foundation's NSData compression (macOS 10.15+ / iOS 13+). Isolated here
    // so a CI SDK difference is a one-line fix.
    nonisolated private static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    nonisolated private static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}
