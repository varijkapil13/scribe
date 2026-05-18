import CoreServices
import Foundation

/// FSEvents-based watcher over the markdown vault root. Coalesces bursts
/// of file changes (write + rename + delete) into a single callback so
/// the reconciler doesn't run a dozen times for one editor save.
///
/// Slice 4 uses this as a "kick the reconciler" signal — no per-file
/// diffing, no event-flag inspection. When iCloud Drive syncs in a
/// remote edit, when the user saves in Obsidian, when an external tool
/// drops a file in the vault — the same callback fires.
final class NoteVaultWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let onChange: () -> Void

    init(
        root: URL,
        latency: TimeInterval = 0.5,
        queue: DispatchQueue = .global(qos: .utility),
        onChange: @escaping () -> Void
    ) {
        self.root = root
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [root.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<NoteVaultWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Log.storage.error("NoteVaultWatcher: FSEventStreamCreate returned nil for \(self.root.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        Log.storage.info("NoteVaultWatcher: watching \(self.root.path, privacy: .public) at latency=\(self.latency)s")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
