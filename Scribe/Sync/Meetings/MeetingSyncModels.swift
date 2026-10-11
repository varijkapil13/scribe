import Foundation
#if os(iOS)
import UIKit
#endif

// Value types for CloudKit meeting sync. All Foundation-only and Sendable so
// they cross from the sync engine actor to the CloudKit service and the UI.
//
// Cross-device identity: a session is keyed by its (globally unique) String
// id. Segments are NEVER identified by their local Int64 row ids — a
// session's whole transcript travels as one payload (`MeetingTranscriptPayload`)
// whose entries are ordered by an ordinal, and importing it replaces the
// session's segments wholesale. Bookmarks travel the same way (by value).

// MARK: - Device kind

/// Which kind of device recorded a meeting; drives the "from iPhone" badge.
enum MeetingDeviceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case mac
    case iPhone = "iphone"
    case iPad = "ipad"

    /// Badge text shown on meetings recorded on another device.
    var originBadgeLabel: String {
        switch self {
        case .mac: return "from Mac"
        case .iPhone: return "from iPhone"
        case .iPad: return "from iPad"
        }
    }

    /// "Mac" / "iPhone" / "iPad".
    var deviceName: String {
        switch self {
        case .mac: return "Mac"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        }
    }

    /// The kind of the device this app runs on. Main-actor because UIKit's
    /// `UIDevice` is.
    @MainActor static func current() -> MeetingDeviceKind {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #else
        return .iPhone
        #endif
    }
}

// MARK: - Session snapshot

/// A bookmark ("Mark moment") by value — local row ids don't travel.
struct MeetingSyncBookmark: Codable, Equatable, Hashable, Sendable {
    var offsetMs: Int
    var label: String?
    var createdAt: Date
}

/// One retained-audio file of a session available in iCloud.
struct MeetingAudioFileInfo: Codable, Equatable, Hashable, Sendable {
    var fileName: String
    var byteCount: Int64
}

/// Everything about a meeting except its transcript text: the wire shape of
/// the `MeetingSession` CloudKit record. A deletion is the same record with
/// `isDeleted` set (a tombstone carries its own `updatedAt`, so last-writer-
/// wins also covers delete-vs-edit races).
struct MeetingSessionSnapshot: Equatable, Sendable {
    var id: String
    var title: String
    var noteId: String?
    var createdAt: Date
    var endedAt: Date?
    var durationSeconds: Int?
    var language: String?
    var tags: [String]
    var calendarEventId: String?
    var calendarEventTitle: String?
    var attendees: [CalendarAttendee]
    /// `MeetingSummary` as JSON (see `MeetingSyncJSON`), nil when none.
    var summaryJSON: String?
    /// Per-session speaker names keyed by speaker key (`session_speakers`).
    var speakerNames: [String: String]
    var bookmarks: [MeetingSyncBookmark]
    var isDeleted: Bool
    /// Last-writer-wins clock.
    var updatedAt: Date
    /// Device that recorded the meeting (kept as-is when another device
    /// edits and re-pushes it).
    var originDevice: MeetingDeviceKind?
    var originDeviceId: String?
    /// `MeetingTranscriptCodec.hash` of the transcript that goes with this
    /// version, nil when there is none (tombstones).
    var transcriptHash: String?
    var segmentCount: Int
    /// Audio files uploaded for this session ("Sync recording audio").
    var audioFiles: [MeetingAudioFileInfo]

    init(
        id: String,
        title: String,
        noteId: String? = nil,
        createdAt: Date,
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        language: String? = nil,
        tags: [String] = [],
        calendarEventId: String? = nil,
        calendarEventTitle: String? = nil,
        attendees: [CalendarAttendee] = [],
        summaryJSON: String? = nil,
        speakerNames: [String: String] = [:],
        bookmarks: [MeetingSyncBookmark] = [],
        isDeleted: Bool = false,
        updatedAt: Date,
        originDevice: MeetingDeviceKind? = nil,
        originDeviceId: String? = nil,
        transcriptHash: String? = nil,
        segmentCount: Int = 0,
        audioFiles: [MeetingAudioFileInfo] = []
    ) {
        self.id = id
        self.title = title
        self.noteId = noteId
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.language = language
        self.tags = tags
        self.calendarEventId = calendarEventId
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.summaryJSON = summaryJSON
        self.speakerNames = speakerNames
        self.bookmarks = bookmarks
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
        self.originDevice = originDevice
        self.originDeviceId = originDeviceId
        self.transcriptHash = transcriptHash
        self.segmentCount = segmentCount
        self.audioFiles = audioFiles
    }

    /// The record pushed for a session deleted on this device.
    nonisolated static func tombstone(id: String, deletedAt: Date) -> MeetingSessionSnapshot {
        MeetingSessionSnapshot(
            id: id,
            title: "",
            createdAt: deletedAt,
            isDeleted: true,
            updatedAt: deletedAt
        )
    }
}

// MARK: - Settings

/// User-facing switches. Meeting sync rides on the existing iCloud opt-in
/// (`CloudKitSyncService.enabledDefaultsKey`) plus its own sub-toggle; audio
/// upload is a further opt-in. Both sub-toggles default OFF: transcripts and
/// recordings never leave the device without an explicit choice.
enum MeetingSyncSettings {
    nonisolated static let enabledKey = "meetingSync.enabled"
    nonisolated static let audioEnabledKey = "meetingSync.audioEnabled"

    /// "Sync meetings" (needs the iCloud toggle too).
    nonisolated static func isMeetingSyncOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: CloudKitSyncService.enabledDefaultsKey) && defaults.bool(forKey: enabledKey)
    }

    /// "Sync recording audio" (needs "Sync meetings").
    nonisolated static func isAudioSyncOn(_ defaults: UserDefaults = .standard) -> Bool {
        isMeetingSyncOn(defaults) && defaults.bool(forKey: audioEnabledKey)
    }

    /// Toggles on AND a CloudKit-entitled build (constructing a CKContainer
    /// without the entitlement crashes; see `CloudKitAvailability`).
    nonisolated static func canSync(_ defaults: UserDefaults = .standard) -> Bool {
        isMeetingSyncOn(defaults) && CloudKitAvailability.isCloudKitEntitled
    }
}

// MARK: - Audio limits

/// Which retained-audio files may sync, and how big they may be.
enum MeetingAudioSyncPolicy {
    /// Only these names are uploaded or written on download — a remote
    /// record can never make us write outside the session's audio folder.
    nonisolated static let allowedFileNames: [String] = [
        SessionAudioStorage.micFileName,
        SessionAudioStorage.systemFileName,
        "timing.json"
    ]

    /// Per-file cap (CloudKit assets are limited; long recordings are large).
    nonisolated static let maxFileBytes: Int64 = 200 * 1024 * 1024
    /// Per-session cap across all files.
    nonisolated static let maxSessionBytes: Int64 = 400 * 1024 * 1024

    nonisolated static func isAllowed(fileName: String) -> Bool {
        allowedFileNames.contains(fileName)
    }

    /// Picks the files to upload from `(name, size)` candidates: allowed
    /// names only, each within `maxFile`, in `allowedFileNames` order, while
    /// the running total stays within `maxTotal`. Pure.
    nonisolated static func selectUploads(
        _ candidates: [MeetingAudioFileInfo],
        maxFile: Int64 = maxFileBytes,
        maxTotal: Int64 = maxSessionBytes
    ) -> [MeetingAudioFileInfo] {
        var picked: [MeetingAudioFileInfo] = []
        var total: Int64 = 0
        for name in allowedFileNames {
            guard let file = candidates.first(where: { $0.fileName == name }) else { continue }
            guard file.byteCount > 0, file.byteCount <= maxFile, total + file.byteCount <= maxTotal else { continue }
            picked.append(file)
            total += file.byteCount
        }
        return picked
    }

    /// The allowed files present in `directory`, with their sizes.
    nonisolated static func localFiles(in directory: URL) -> [MeetingAudioFileInfo] {
        allowedFileNames.compactMap { name -> MeetingAudioFileInfo? in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            return MeetingAudioFileInfo(fileName: name, byteCount: size)
        }
    }
}

// MARK: - JSON helpers

/// Deterministic JSON for the small structured fields carried on the session
/// record (sorted keys so equal values encode to equal text).
enum MeetingSyncJSON {
    nonisolated static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted on the main actor after a sync round imported or deleted
    /// meetings; `object` is the `[String]` of affected session ids.
    static let scribeMeetingSyncDidChangeSessions = Notification.Name("scribe.meetingSync.didChangeSessions")
}
