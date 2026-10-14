import Foundation

/// The one serial executor for note-file writes. Every read-modify-write of a
/// note's file runs its read and its write inside a single `run`, so no write
/// is based on a version another write is about to replace.
///
/// Work on the queue must never wait synchronously for the main thread: the
/// main thread blocks on `run` and `drain`.
enum NoteWriteQueue {
    enum Writer: Equatable, Sendable {
        case editor(UUID)
        case other
    }

    private struct RecordedWrite {
        let writer: Writer
        let baseHash: String?
        let writtenHash: String
    }

    private static let key = DispatchSpecificKey<Bool>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.varij.scribe.note-write", qos: .userInitiated)
        queue.setSpecific(key: key, value: true)
        return queue
    }()
    nonisolated(unsafe) private static var writes: [String: [RecordedWrite]] = [:]
    private static let maxWritesPerNote = 32

    static var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }

    /// Runs `body` on the queue and waits for it; inline when already on it.
    static func run<T>(_ body: () throws -> T) rethrows -> T {
        if isCurrent { return try body() }
        return try queue.sync(execute: body)
    }

    static func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Blocks until every write queued so far has landed.
    static func drain() {
        Perf.measure("note.write.drain") { run {} }
    }

    static func recordWrite(noteId: String, by writer: Writer,
                            base: NoteFileFingerprint?, written: NoteFileFingerprint) {
        dispatchPrecondition(condition: .onQueue(queue))
        var log = writes[noteId] ?? []
        log.append(RecordedWrite(writer: writer, baseHash: base?.contentHash, writtenHash: written.contentHash))
        if log.count > maxWritesPerNote { log.removeFirst(log.count - maxWritesPerNote) }
        writes[noteId] = log
    }

    /// Whether a recorded write by anyone but `editor` replaced `base` or a
    /// version descending from it.
    static func hasForeignWrite(noteId: String, since base: NoteFileFingerprint, editor: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let log = writes[noteId] else { return false }
        var hash = base.contentHash
        for _ in log.indices {
            guard let next = log.last(where: { $0.baseHash == hash }) else { return false }
            if next.writer != .editor(editor) { return true }
            hash = next.writtenHash
        }
        return false
    }
}

extension NoteStore {
    /// Runs a read-modify-write of note `id` on `NoteWriteQueue` and records
    /// any file write it made as `writer`'s.
    func modifyNote<T>(id: String, by writer: NoteWriteQueue.Writer, _ body: () throws -> T) rethrows -> T {
        try NoteWriteQueue.run {
            let lastBefore = lastWrittenFileFingerprint(forNoteId: id)
            let base = currentFileFingerprint(forNoteId: id, reusing: lastBefore)
            defer {
                if let written = lastWrittenFileFingerprint(forNoteId: id), written != lastBefore {
                    NoteWriteQueue.recordWrite(noteId: id, by: writer, base: base, written: written)
                }
            }
            return try body()
        }
    }
}
