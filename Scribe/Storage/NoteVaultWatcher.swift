import CoreServices
import Foundation

/// FSEvents-based watcher over the markdown vault root. FSEvents batches
/// bursts of file changes (write + rename + delete) within `latency` into
/// a single callback carrying the affected paths, so the caller can skip
/// events explained by Scribe's own writes (`VaultWriteGuard`) and kick the
/// reconciler for everything else — iCloud Drive syncing a remote edit, a
/// save in Obsidian, an external tool dropping a file in the vault.
final class NoteVaultWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable ([NoteVaultEvent]) -> Void

    init(
        root: URL,
        latency: TimeInterval = 0.5,
        queue: DispatchQueue = .global(qos: .utility),
        onChange: @escaping @Sendable ([NoteVaultEvent]) -> Void
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
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<NoteVaultWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.onChange(NoteVaultWatcher.events(
                    count: numEvents,
                    paths: eventPaths,
                    flags: eventFlags
                ))
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

    /// Decodes one FSEvents callback. With `kFSEventStreamCreateFlagUseCFTypes`
    /// the paths arrive as a `CFArray` of `CFString`. Parameters are optional
    /// so this compiles whether the SDK imports the callback's pointers as
    /// optional or not.
    private static func events(
        count: Int,
        paths: UnsafeMutableRawPointer?,
        flags: UnsafePointer<FSEventStreamEventFlags>?
    ) -> [NoteVaultEvent] {
        guard let paths, let flags else {
            return [NoteVaultEvent(path: "", requiresFullScan: true)]
        }
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        let strings = array.compactMap { $0 as? String }
        let fullScanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
        )
        let dirMask = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        var out: [NoteVaultEvent] = []
        for i in 0..<min(count, strings.count) {
            let f = flags[i]
            out.append(NoteVaultEvent(
                path: strings[i],
                isDirectory: (f & dirMask) != 0,
                requiresFullScan: (f & fullScanMask) != 0
            ))
        }
        // A callback with no decodable path still means "something changed".
        if out.isEmpty && count > 0 {
            out.append(NoteVaultEvent(path: "", requiresFullScan: true))
        }
        return out
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
