import CloudKit
import Foundation

/// Live `MeetingCloudServicing` over the private database's `Meetings` zone
/// (its own zone — task sync's `Tasks` zone is untouched).
///
/// ⚠️ DEVICE-VALIDATION REQUIRED: needs a signed-in iCloud account and the
/// provisioned `iCloud.com.varij.scribe` container, so the network calls
/// below are not exercised in CI. The record mapping (`MeetingCloudRecord`)
/// and everything above this layer are unit-tested.
///
/// Only construct it when `CloudKitAvailability.isCloudKitEntitled` — a
/// CKContainer in an unentitled build raises an Objective-C exception.
///
/// `@unchecked Sendable`: every stored property is immutable after init, and
/// CloudKit's database object is thread-safe.
final class MeetingCloudKitService: MeetingCloudServicing, @unchecked Sendable {

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(containerIdentifier: String) {
        self.database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: MeetingCloudRecord.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Zone

    func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
    }

    // MARK: - Pull

    func fetchChanges(since token: Data?) async throws -> MeetingCloudChangeBatch {
        let serverToken = token.flatMap(Self.unarchiveToken)
        do {
            let changes = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: serverToken,
                desiredKeys: MeetingCloudRecord.desiredKeys,
                resultsLimit: nil
            )
            var batch = MeetingCloudChangeBatch()
            for (_, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result else { continue }
                let record = modification.record
                switch record.recordType {
                case MeetingCloudRecord.sessionType:
                    if let snapshot = MeetingCloudRecord.snapshot(from: record) {
                        batch.sessions.append(snapshot)
                    }
                case MeetingCloudRecord.transcriptType:
                    // Read the asset now: its file is a CloudKit cache file.
                    if let sessionId = MeetingCloudRecord.transcriptSessionId(of: record),
                       let payload = MeetingCloudRecord.transcript(from: record) {
                        batch.transcripts[sessionId] = payload
                    }
                default:
                    break
                }
            }
            batch.removedSessionIds = changes.deletions
                .filter { $0.recordType == MeetingCloudRecord.sessionType }
                .map { $0.recordID.recordName }
            batch.token = Self.archiveToken(changes.changeToken)
            batch.moreComing = changes.moreComing
            return batch
        } catch let error as CKError {
            throw Self.mapped(error)
        }
    }

    func fetchTranscript(sessionId: String) async throws -> MeetingTranscriptPayload? {
        let id = CKRecord.ID(recordName: MeetingCloudRecord.transcriptRecordName(sessionId: sessionId), zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            return MeetingCloudRecord.transcript(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError {
            throw Self.mapped(error)
        }
    }

    // MARK: - Push

    func saveSession(_ snapshot: MeetingSessionSnapshot, transcript: MeetingTranscriptPayload?) async throws -> Bool {
        var records = [MeetingCloudRecord.makeSessionRecord(snapshot, in: zoneID)]
        var temporaryFiles: [URL] = []
        defer {
            for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        }
        if let transcript {
            let data = try MeetingTranscriptCodec.encode(transcript)
            let url = try Self.temporaryFileURL()
            try data.write(to: url, options: .atomic)
            temporaryFiles.append(url)
            records.append(MeetingCloudRecord.makeTranscriptRecord(
                sessionId: snapshot.id,
                payloadHash: MeetingTranscriptCodec.hash(transcript),
                assetURL: url,
                in: zoneID
            ))
        }
        do {
            // `.allKeys`: last-writer-wins was decided by the pull that
            // preceded this push, so overwrite whatever the server holds.
            let result = try await database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            var allSaved = true
            for record in records {
                switch result.saveResults[record.recordID] {
                case .success?:
                    break
                case .failure(let error)?:
                    allSaved = false
                    Log.storage.error("Meeting sync save failed: \(error.localizedDescription, privacy: .public)")
                case nil:
                    allSaved = false
                }
            }
            return allSaved
        } catch let error as CKError {
            throw Self.mapped(error)
        }
    }

    func uploadAudio(sessionId: String, files: [MeetingAudioUpload]) async throws -> [MeetingAudioFileInfo] {
        var uploaded: [MeetingAudioFileInfo] = []
        // One file per request: recordings are large, and one failure
        // shouldn't discard the others.
        for file in files {
            let record = MeetingCloudRecord.makeAudioRecord(
                sessionId: sessionId,
                file: file.info,
                fileURL: file.fileURL,
                in: zoneID
            )
            do {
                let result = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: false
                )
                if case .success? = result.saveResults[record.recordID] {
                    uploaded.append(file.info)
                }
            } catch let error as CKError {
                throw Self.mapped(error)
            }
        }
        return uploaded
    }

    func deleteSessionPayloads(sessionId: String) async throws {
        var ids = [CKRecord.ID(recordName: MeetingCloudRecord.transcriptRecordName(sessionId: sessionId), zoneID: zoneID)]
        for name in MeetingAudioSyncPolicy.allowedFileNames {
            ids.append(CKRecord.ID(recordName: MeetingCloudRecord.audioRecordName(sessionId: sessionId, fileName: name), zoneID: zoneID))
        }
        do {
            // Not atomic: most of these usually don't exist (unknownItem).
            _ = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
        } catch let error as CKError {
            throw Self.mapped(error)
        }
    }

    func downloadAudio(sessionId: String, fileName: String, to destination: URL) async throws {
        guard MeetingAudioSyncPolicy.isAllowed(fileName: fileName) else { throw MeetingCloudServiceError.recordMissing }
        let id = CKRecord.ID(recordName: MeetingCloudRecord.audioRecordName(sessionId: sessionId, fileName: fileName), zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            throw MeetingCloudServiceError.recordMissing
        } catch let error as CKError {
            throw Self.mapped(error)
        }
        guard let source = MeetingCloudRecord.audioFileURL(from: record) else {
            throw MeetingCloudServiceError.recordMissing
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    // MARK: - Helpers

    private static func mapped(_ error: CKError) -> Error {
        switch error.code {
        case .changeTokenExpired: return MeetingCloudServiceError.changeTokenExpired
        case .zoneNotFound, .userDeletedZone: return MeetingCloudServiceError.zoneMissing
        default: return error
        }
    }

    private static func temporaryFileURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeMeetingSync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString + ".smt")
    }

    private static func archiveToken(_ token: CKServerChangeToken?) -> Data? {
        guard let token else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchiveToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
