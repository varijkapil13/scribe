import Foundation
import Darwin

// macOS only: spawns user executables with `Process`. Lives outside
// Scribe/Storage so the iOS target never compiles it.

// MARK: - Settings

/// Post-meeting hook preferences (UserDefaults).
enum MeetingHookSettings {
    /// Bool — master toggle. Default off.
    static let enabledKey = "postMeetingHooksEnabled"
    /// [String] — absolute paths of hook executables, run in order.
    static let pathsKey = "postMeetingHookPaths"

    /// Per-hook wall-clock limit before the process is terminated.
    static let timeout: TimeInterval = 60
    /// How long to wait for auto-summary before running hooks without it.
    static let summaryWait: TimeInterval = 45

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func hookPaths(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: pathsKey) ?? []).filter { !$0.isEmpty }
    }

    static func setHookPaths(_ paths: [String], _ defaults: UserDefaults = .standard) {
        defaults.set(paths, forKey: pathsKey)
    }
}

// MARK: - Runner

/// Outcome of one hook run.
struct MeetingHookResult: Sendable {
    let path: String
    let exitCode: Int32?
    let timedOut: Bool
    let launchError: String?
    /// Tail of stderr (capped) for diagnostics.
    let stderr: String

    var succeeded: Bool { launchError == nil && !timedOut && exitCode == 0 }

    var failureDescription: String {
        let name = (path as NSString).lastPathComponent
        if let launchError { return "\(name) couldn't start: \(launchError)" }
        if timedOut { return "\(name) timed out after \(Int(MeetingHookSettings.timeout))s" }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = exitCode.map { String($0) } ?? "?"
        return detail.isEmpty
            ? "\(name) exited with status \(code)"
            : "\(name) exited with status \(code): \(detail.suffix(200))"
    }
}

enum MeetingHookRunner {

    /// Runs `executablePath` with `stdin` piped in and `environment` merged
    /// over Scribe's own. Never throws; failures come back in the result.
    static func run(
        executablePath: String,
        stdin: Data,
        environment: [String: String],
        timeout: TimeInterval = MeetingHookSettings.timeout
    ) async -> MeetingHookResult {
        // A plain dispatch thread (not the cooperative pool) because the
        // wait below sleeps for up to `timeout`.
        await withCheckedContinuation { (continuation: CheckedContinuation<MeetingHookResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(
                    executablePath: executablePath, stdin: stdin,
                    environment: environment, timeout: timeout))
            }
        }
    }

    /// Hands a FileHandle to the stdin-writer thread. Sound: only that
    /// thread touches it after hand-off.
    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Thread-safe, size-capped byte sink for stderr.
    private final class CappedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let cap = 16 * 1024

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            if data.count > cap { data = data.suffix(cap) }
        }

        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func runBlocking(
        executablePath: String,
        stdin: Data,
        environment: [String: String],
        timeout: TimeInterval
    ) -> MeetingHookResult {
        let url = URL(fileURLWithPath: executablePath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return MeetingHookResult(path: executablePath, exitCode: nil, timedOut: false,
                                     launchError: "not an executable file (chmod +x?)", stderr: "")
        }

        let process = Process()
        process.executableURL = url
        process.currentDirectoryURL = url.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env

        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        let errBuffer = CappedBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBuffer.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            return MeetingHookResult(path: executablePath, exitCode: nil, timedOut: false,
                                     launchError: error.localizedDescription, stderr: "")
        }

        // Feed stdin on its own thread: a large payload can exceed the pipe
        // buffer, and a hook that never reads stdin must not wedge us. No
        // SIGPIPE if the hook exits early — the write just fails.
        let writer = UncheckedBox(inPipe.fileHandleForWriting)
        _ = fcntl(writer.value.fileDescriptor, F_SETNOSIGPIPE, 1)
        let input = stdin
        DispatchQueue.global(qos: .utility).async {
            try? writer.value.write(contentsOf: input)
            try? writer.value.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                // Escalate if SIGTERM is ignored.
                let killDeadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        // Give the readability handler a beat to flush the final chunk, then
        // detach it. (No blocking drain: a backgrounded grandchild could hold
        // stderr open forever.)
        Thread.sleep(forTimeInterval: 0.1)
        errPipe.fileHandleForReading.readabilityHandler = nil

        return MeetingHookResult(
            path: executablePath,
            exitCode: timedOut ? nil : process.terminationStatus,
            timedOut: timedOut,
            launchError: nil,
            stderr: errBuffer.string
        )
    }
}

// MARK: - Coordinator

/// Runs the configured hooks after a recording stops.
@MainActor
enum MeetingHooks {

    /// Entry point from `AppState.stopSession`. Returns immediately; the
    /// hooks run in the background after auto-summary (when enabled)
    /// finishes or `MeetingHookSettings.summaryWait` elapses.
    static func sessionDidStop(sessionId: String?, appState: AppState) {
        guard let sessionId, MeetingHookSettings.isEnabled() else { return }
        let paths = MeetingHookSettings.hookPaths()
        guard !paths.isEmpty else { return }
        let store = appState.transcriptStore
        let shouldWaitForSummary = UserDefaults.standard.bool(forKey: "autoSummarize")
            && AppleIntelligenceAvailability.current.isAvailable

        Task { [weak appState] in
            if shouldWaitForSummary {
                await waitForSummary(sessionId: sessionId, store: store)
            }
            let failures = await runAll(paths: paths, sessionId: sessionId, store: store)
            for failure in failures {
                appState?.report("Post-meeting hook failed — \(failure)")
            }
        }
    }

    /// Runs every hook for `sessionId`, returning failure descriptions.
    /// Also used by the settings pane's "Run on latest meeting" button.
    static func runAll(paths: [String], sessionId: String, store: TranscriptStore) async -> [String] {
        guard let session = try? store.fetchSession(id: sessionId) else {
            return ["meeting \(sessionId) not found"]
        }
        let segments = (try? store.fetchSegments(sessionId: sessionId)) ?? []
        let summary = try? store.fetchSummary(sessionId: sessionId)
        let completed = (try? store.fetchCompletedActionItemIds(sessionId: sessionId)) ?? []
        let resolver = store.speakerResolver(sessionId: sessionId)

        var noteTitle: String?
        var notePath: String?
        if let noteId = session.noteId {
            noteTitle = (try? NoteStore.shared.fetchNote(id: noteId))?.title
            notePath = await Task.detached(priority: .utility) {
                (try? NoteStore.shared.fileStore?.findURL(for: noteId))?.path
            }.value
        }

        let payload = MeetingHookPayload.make(
            session: session,
            segments: segments,
            speakerNames: resolver,
            noteTitle: noteTitle,
            notePath: notePath,
            summary: summary,
            completedActionItemIds: completed
        )
        let data: Data
        do {
            data = try payload.jsonData()
        } catch {
            Log.app.error("Hook payload encoding failed: \(error.localizedDescription, privacy: .public)")
            return ["couldn't encode meeting: \(error.localizedDescription)"]
        }

        let environment = [
            "SCRIBE_SESSION_ID": sessionId,
            "SCRIBE_NOTE_PATH": notePath ?? "",
            "SCRIBE_NOTE_ID": session.noteId ?? "",
            "SCRIBE_EVENT": MeetingHookPayload.endedEvent,
        ]

        var failures: [String] = []
        for path in paths {
            Log.app.info("Running post-meeting hook \(path, privacy: .public)")
            let result = await MeetingHookRunner.run(executablePath: path, stdin: data, environment: environment)
            if result.succeeded {
                Log.app.info("Post-meeting hook succeeded: \(path, privacy: .public)")
            } else {
                // failureDescription carries the hook's stderr tail, which may
                // include meeting content or secrets — keep it out of public logs.
                let hookName = (path as NSString).lastPathComponent
                Log.app.error("Post-meeting hook failed: \(hookName, privacy: .public): \(result.failureDescription, privacy: .private)")
                failures.append(result.failureDescription)
            }
        }
        return failures
    }

    /// Polls for the auto-summary to land, up to `summaryWait`.
    private static func waitForSummary(sessionId: String, store: TranscriptStore) async {
        let segments = (try? store.fetchSegments(sessionId: sessionId)) ?? []
        guard !segments.isEmpty else { return }
        let deadline = Date().addingTimeInterval(MeetingHookSettings.summaryWait)
        while Date() < deadline {
            if (try? store.fetchSummary(sessionId: sessionId)) != nil { return }
            try? await Task.sleep(for: .seconds(1.5))
        }
        Log.app.info("Hooks: auto-summary not ready after \(Int(MeetingHookSettings.summaryWait))s; running without it.")
    }
}
