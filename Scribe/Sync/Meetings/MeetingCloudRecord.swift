import CloudKit
import Foundation

/// Wire format of meeting sync in the private database's `Meetings` zone.
/// Pure + synchronous (no network), so the mapping is unit-tested.
///
/// Record types:
/// - `MeetingSession` (record name = session id): metadata, summary,
///   speaker names, bookmarks, the deleted flag and `updatedAt` (LWW clock).
/// - `MeetingTranscript` (`transcript.<sessionId>`): the compressed
///   transcript payload as a CKAsset (`MeetingTranscriptCodec`).
/// - `MeetingAudio` (`audio.<sessionId>.<file>`): one retained-audio file as
///   a CKAsset. Pulls never request its asset key, so audio downloads only
///   on demand.
enum MeetingCloudRecord {

    nonisolated static let zoneName = "Meetings"
    nonisolated static let sessionType = "MeetingSession"
    nonisolated static let transcriptType = "MeetingTranscript"
    nonisolated static let audioType = "MeetingAudio"
    nonisolated static let schemaVersion = 1

    /// Field keys. Distinct across record types so one `desiredKeys` list
    /// can name them all.
    enum Key {
        // MeetingSession
        nonisolated static let title = "title"
        nonisolated static let noteId = "noteId"
        nonisolated static let createdAt = "createdAt"
        nonisolated static let endedAt = "endedAt"
        nonisolated static let durationSeconds = "durationSeconds"
        nonisolated static let language = "language"
        nonisolated static let tagsJSON = "tagsJSON"
        nonisolated static let calendarEventId = "calendarEventId"
        nonisolated static let calendarEventTitle = "calendarEventTitle"
        nonisolated static let attendeesJSON = "attendeesJSON"
        nonisolated static let summaryJSON = "summaryJSON"
        nonisolated static let speakerNamesJSON = "speakerNamesJSON"
        nonisolated static let bookmarksJSON = "bookmarksJSON"
        nonisolated static let isDeleted = "isDeleted"
        nonisolated static let updatedAt = "updatedAt"
        nonisolated static let originDevice = "originDevice"
        nonisolated static let originDeviceId = "originDeviceId"
        nonisolated static let transcriptHash = "transcriptHash"
        nonisolated static let segmentCount = "segmentCount"
        nonisolated static let audioFilesJSON = "audioFilesJSON"
        nonisolated static let schemaVersion = "schemaVersion"
        // MeetingTranscript
        nonisolated static let transcriptSessionId = "transcriptSessionId"
        nonisolated static let transcriptAsset = "transcriptAsset"
        nonisolated static let transcriptPayloadHash = "transcriptPayloadHash"
        // MeetingAudio
        nonisolated static let audioSessionId = "audioSessionId"
        nonisolated static let audioFileName = "audioFileName"
        nonisolated static let audioByteCount = "audioByteCount"
        nonisolated static let audioAsset = "audioAsset"
    }

    /// Every key a pull asks for: all of them except the audio asset.
    nonisolated static let desiredKeys: [String] = [
        Key.title, Key.noteId, Key.createdAt, Key.endedAt, Key.durationSeconds,
        Key.language, Key.tagsJSON, Key.calendarEventId, Key.calendarEventTitle,
        Key.attendeesJSON, Key.summaryJSON, Key.speakerNamesJSON, Key.bookmarksJSON,
        Key.isDeleted, Key.updatedAt, Key.originDevice, Key.originDeviceId,
        Key.transcriptHash, Key.segmentCount, Key.audioFilesJSON, Key.schemaVersion,
        Key.transcriptSessionId, Key.transcriptAsset, Key.transcriptPayloadHash,
        Key.audioSessionId, Key.audioFileName, Key.audioByteCount
    ]

    // MARK: - Record names

    nonisolated static func transcriptRecordName(sessionId: String) -> String {
        "transcript.\(sessionId)"
    }

    nonisolated static func audioRecordName(sessionId: String, fileName: String) -> String {
        "audio.\(sessionId).\(fileName)"
    }

    // MARK: - MeetingSession

    static func makeSessionRecord(_ snapshot: MeetingSessionSnapshot, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: sessionType,
            recordID: CKRecord.ID(recordName: snapshot.id, zoneID: zoneID)
        )
        apply(snapshot, to: record)
        return record
    }

    static func apply(_ snapshot: MeetingSessionSnapshot, to record: CKRecord) {
        record[Key.title] = snapshot.title
        record[Key.noteId] = snapshot.noteId.map { $0 as any CKRecordValueProtocol }
        record[Key.createdAt] = snapshot.createdAt
        record[Key.endedAt] = snapshot.endedAt.map { $0 as any CKRecordValueProtocol }
        record[Key.durationSeconds] = snapshot.durationSeconds.map { $0 as any CKRecordValueProtocol }
        record[Key.language] = snapshot.language.map { $0 as any CKRecordValueProtocol }
        record[Key.tagsJSON] = MeetingSyncJSON.encode(snapshot.tags).map { $0 as any CKRecordValueProtocol }
        record[Key.calendarEventId] = snapshot.calendarEventId.map { $0 as any CKRecordValueProtocol }
        record[Key.calendarEventTitle] = snapshot.calendarEventTitle.map { $0 as any CKRecordValueProtocol }
        record[Key.attendeesJSON] = MeetingSyncJSON.encode(snapshot.attendees).map { $0 as any CKRecordValueProtocol }
        record[Key.summaryJSON] = snapshot.summaryJSON.map { $0 as any CKRecordValueProtocol }
        record[Key.speakerNamesJSON] = MeetingSyncJSON.encode(snapshot.speakerNames).map { $0 as any CKRecordValueProtocol }
        record[Key.bookmarksJSON] = MeetingSyncJSON.encode(snapshot.bookmarks).map { $0 as any CKRecordValueProtocol }
        record[Key.isDeleted] = snapshot.isDeleted ? 1 : 0
        record[Key.updatedAt] = snapshot.updatedAt
        record[Key.originDevice] = snapshot.originDevice.map { $0.rawValue as any CKRecordValueProtocol }
        record[Key.originDeviceId] = snapshot.originDeviceId.map { $0 as any CKRecordValueProtocol }
        record[Key.transcriptHash] = snapshot.transcriptHash.map { $0 as any CKRecordValueProtocol }
        record[Key.segmentCount] = snapshot.segmentCount
        record[Key.audioFilesJSON] = MeetingSyncJSON.encode(snapshot.audioFiles).map { $0 as any CKRecordValueProtocol }
        record[Key.schemaVersion] = schemaVersion
    }

    /// Reconstructs a snapshot; nil when the record isn't a well-formed
    /// `MeetingSession`.
    static func snapshot(from record: CKRecord) -> MeetingSessionSnapshot? {
        guard record.recordType == sessionType,
              let updatedAt = record[Key.updatedAt] as? Date
        else { return nil }
        let isDeleted = ((record[Key.isDeleted] as? Int) ?? 0) != 0
        let createdAt = (record[Key.createdAt] as? Date) ?? updatedAt
        guard isDeleted || record[Key.title] is String else { return nil }

        return MeetingSessionSnapshot(
            id: record.recordID.recordName,
            title: (record[Key.title] as? String) ?? "",
            noteId: record[Key.noteId] as? String,
            createdAt: createdAt,
            endedAt: record[Key.endedAt] as? Date,
            durationSeconds: record[Key.durationSeconds] as? Int,
            language: record[Key.language] as? String,
            tags: MeetingSyncJSON.decode([String].self, from: record[Key.tagsJSON] as? String) ?? [],
            calendarEventId: record[Key.calendarEventId] as? String,
            calendarEventTitle: record[Key.calendarEventTitle] as? String,
            attendees: MeetingSyncJSON.decode([CalendarAttendee].self, from: record[Key.attendeesJSON] as? String) ?? [],
            summaryJSON: record[Key.summaryJSON] as? String,
            speakerNames: MeetingSyncJSON.decode([String: String].self, from: record[Key.speakerNamesJSON] as? String) ?? [:],
            bookmarks: MeetingSyncJSON.decode([MeetingSyncBookmark].self, from: record[Key.bookmarksJSON] as? String) ?? [],
            isDeleted: isDeleted,
            updatedAt: updatedAt,
            originDevice: (record[Key.originDevice] as? String).flatMap(MeetingDeviceKind.init(rawValue:)),
            originDeviceId: record[Key.originDeviceId] as? String,
            transcriptHash: record[Key.transcriptHash] as? String,
            segmentCount: (record[Key.segmentCount] as? Int) ?? 0,
            audioFiles: MeetingSyncJSON.decode([MeetingAudioFileInfo].self, from: record[Key.audioFilesJSON] as? String) ?? []
        )
    }

    // MARK: - MeetingTranscript

    static func makeTranscriptRecord(
        sessionId: String,
        payloadHash: String,
        assetURL: URL,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: transcriptType,
            recordID: CKRecord.ID(recordName: transcriptRecordName(sessionId: sessionId), zoneID: zoneID)
        )
        record[Key.transcriptSessionId] = sessionId
        record[Key.transcriptPayloadHash] = payloadHash
        record[Key.transcriptAsset] = CKAsset(fileURL: assetURL)
        return record
    }

    /// The session id a transcript record belongs to.
    static func transcriptSessionId(of record: CKRecord) -> String? {
        guard record.recordType == transcriptType else { return nil }
        return record[Key.transcriptSessionId] as? String
    }

    /// Reads and decodes a transcript record's asset (nil when it's missing
    /// or not a transcript).
    static func transcript(from record: CKRecord) -> MeetingTranscriptPayload? {
        guard record.recordType == transcriptType,
              let asset = record[Key.transcriptAsset] as? CKAsset,
              let url = asset.fileURL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? MeetingTranscriptCodec.decode(data)
    }

    // MARK: - MeetingAudio

    static func makeAudioRecord(
        sessionId: String,
        file: MeetingAudioFileInfo,
        fileURL: URL,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: audioType,
            recordID: CKRecord.ID(
                recordName: audioRecordName(sessionId: sessionId, fileName: file.fileName),
                zoneID: zoneID
            )
        )
        record[Key.audioSessionId] = sessionId
        record[Key.audioFileName] = file.fileName
        record[Key.audioByteCount] = Int(file.byteCount)
        record[Key.audioAsset] = CKAsset(fileURL: fileURL)
        return record
    }

    /// The downloaded file of an audio record (fetched with its asset).
    static func audioFileURL(from record: CKRecord) -> URL? {
        guard record.recordType == audioType,
              let asset = record[Key.audioAsset] as? CKAsset else { return nil }
        return asset.fileURL
    }
}
