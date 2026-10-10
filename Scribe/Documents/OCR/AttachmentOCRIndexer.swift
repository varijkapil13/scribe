// Scribe/Documents/OCR/AttachmentOCRIndexer.swift
//
// Background OCR of vault attachments (`<vault>/attachments/**`): images and
// PDFs are recognized once and their text stored in `attachment_text`
// (+ FTS), so note search finds text inside images and scanned PDFs.
//
// Incremental: a file is re-read only when its size or modification time
// changed, and re-recognized only when its content hash changed.
// Throttled: passes run at utility priority, a bounded number of files per
// pass with a pause between files, at most every few minutes (sooner after
// a vault change, debounced).

import CryptoKit
import Foundation

/// Stat facts of one attachment on disk.
struct AttachmentFileStat: Equatable, Sendable {
    var relativePath: String
    var size: Int64
    var modifiedAt: Double
}

/// Pure planning for one indexing pass.
enum AttachmentOCRPlanner {

    struct Plan: Equatable, Sendable {
        /// Files whose stat differs from the stored record (or that have
        /// none), newest first, at most `limit`.
        var toCheck: [AttachmentFileStat]
        /// Stored paths whose file no longer exists.
        var removals: [String]
        /// Files still waiting after this pass (beyond `limit`).
        var remaining: Int
    }

    nonisolated static func plan(
        files: [AttachmentFileStat],
        records: [String: AttachmentTextRecord],
        limit: Int
    ) -> Plan {
        let present = Set(files.map(\.relativePath))
        let removals = records.keys.filter { !present.contains($0) }.sorted()
        let changed = files.filter { file in
            guard let record = records[file.relativePath] else { return true }
            return record.fileSize != file.size || record.modifiedAt != file.modifiedAt
        }
        .sorted { lhs, rhs in
            lhs.modifiedAt != rhs.modifiedAt ? lhs.modifiedAt > rhs.modifiedAt : lhs.relativePath < rhs.relativePath
        }
        let capped = Array(changed.prefix(max(0, limit)))
        return Plan(toCheck: capped, removals: removals, remaining: changed.count - capped.count)
    }

    /// True when the stored record already describes these bytes.
    nonisolated static func isUnchanged(record: AttachmentTextRecord?, contentHash: String) -> Bool {
        record?.contentHash == contentHash
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}

/// Preferences for document features.
enum DocumentsPreferences {
    /// Background OCR of attachments (default on).
    static let ocrEnabledKey = "documents.ocrEnabled"
}

/// Runs the background OCR passes.
@MainActor
final class AttachmentOCRIndexer: ObservableObject {

    static let shared = AttachmentOCRIndexer()

    /// Files per pass.
    nonisolated static let filesPerPass = 25
    /// Pause between two files, so OCR never saturates the CPU.
    nonisolated static let pauseBetweenFiles: Duration = .milliseconds(400)
    /// Minimum spacing of scheduled passes.
    nonisolated static let periodicInterval: TimeInterval = 10 * 60
    /// Debounce after a vault change.
    nonisolated static let changeDebounce: TimeInterval = 20
    /// Larger files aren't recognized.
    nonisolated static let maximumFileBytes: Int64 = 60 * 1024 * 1024

    @Published private(set) var isRunning = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var lastPassAt: Date?

    private var timer: Timer?
    private var pendingWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var rerunRequested = false

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DocumentsPreferences.ocrEnabledKey) as? Bool ?? true
    }

    /// Starts periodic passes and listens for vault changes. Idempotent.
    func start() {
        guard timer == nil else { return }
        refreshCount()
        let timer = Timer(timeInterval: Self.periodicInterval, repeats: true) { _ in
            Task { @MainActor in AttachmentOCRIndexer.shared.requestPass(after: 0) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        for name in [Notification.Name.noteVaultFilesChanged, .scribeNoteEditorDidSave] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    AttachmentOCRIndexer.shared.requestPass(after: AttachmentOCRIndexer.changeDebounce)
                }
            }
            observers.append(token)
        }
        // First pass shortly after launch, once the vault reconcile settled.
        requestPass(after: 45)
    }

    /// Schedules a pass `delay` seconds from now (coalescing requests).
    func requestPass(after delay: TimeInterval) {
        guard isEnabled else { return }
        pendingWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { AttachmentOCRIndexer.shared.runPass() }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs one pass now (no-op while one is running; another follows).
    func runPass() {
        guard isEnabled else { return }
        guard !isRunning else {
            rerunRequested = true
            return
        }
        // Same root the editor serves attachments from.
        guard NoteStore.shared.fileStore != nil else { return }
        let root = AttachmentsDirectory.defaultRoot()
        isRunning = true
        let store = AttachmentTextStore.shared
        Task {
            let remaining = await Task.detached(priority: .utility) {
                await Self.indexPass(root: root, store: store)
            }.value
            self.isRunning = false
            self.lastPassAt = Date()
            self.refreshCount()
            if remaining > 0 || self.rerunRequested {
                self.rerunRequested = false
                self.requestPass(after: 5)
            }
        }
    }

    private func refreshCount() {
        indexedCount = (try? AttachmentTextStore.shared.recordCount()) ?? 0
    }

    // MARK: - Pass (background)

    /// One throttled pass. Returns how many changed files are still waiting.
    nonisolated static func indexPass(root: URL, store: AttachmentTextStore) async -> Int {
        let files = attachmentFiles(under: root)
        let records = Dictionary(
            ((try? store.allRecords()) ?? []).map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plan = AttachmentOCRPlanner.plan(files: files, records: records, limit: filesPerPass)
        do {
            try store.remove(paths: plan.removals)
        } catch {
            Log.storage.error("Attachment OCR: removing stale rows failed: \(error.localizedDescription, privacy: .public)")
        }
        for file in plan.toCheck {
            if Task.isCancelled { break }
            index(file, root: root, existing: records[file.relativePath], store: store)
            try? await Task.sleep(for: pauseBetweenFiles)
        }
        return plan.remaining
    }

    /// Hashes the file; re-recognizes only when the bytes changed.
    nonisolated static func index(
        _ file: AttachmentFileStat,
        root: URL,
        existing: AttachmentTextRecord?,
        store: AttachmentTextStore
    ) {
        let url = root.appendingPathComponent(file.relativePath)
        guard let kind = AttachmentTextRecognizer.kind(forPath: file.relativePath) else { return }
        do {
            let hash: String
            if file.size > maximumFileBytes {
                hash = "too-large-\(file.size)"
            } else {
                hash = AttachmentOCRPlanner.sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe))
            }
            if AttachmentOCRPlanner.isUnchanged(record: existing, contentHash: hash) {
                try store.touch(path: file.relativePath, fileSize: file.size, modifiedAt: file.modifiedAt)
                return
            }
            let text = file.size > maximumFileBytes ? "" : ((try? AttachmentTextRecognizer.recognizeText(at: url)) ?? "")
            try store.upsert(AttachmentTextRecord(
                path: file.relativePath,
                noteId: AttachmentTextStore.noteId(forRelativePath: file.relativePath),
                contentHash: hash,
                fileSize: file.size,
                modifiedAt: file.modifiedAt,
                kind: kind.rawValue,
                text: text,
                recognizedAt: Date()
            ))
        } catch {
            Log.storage.error("Attachment OCR failed for \(file.relativePath, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Supported files under `<root>/attachments/`, with stat facts.
    nonisolated static func attachmentFiles(under root: URL) -> [AttachmentFileStat] {
        let folder = root.appendingPathComponent("attachments", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [AttachmentFileStat] = []
        for case let url as URL in enumerator {
            guard AttachmentTextRecognizer.kind(forPath: url.path) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let relative = VaultWriteGuard.relativePath(of: url.path, under: root.path) else { continue }
            out.append(AttachmentFileStat(
                relativePath: relative,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return out
    }
}
