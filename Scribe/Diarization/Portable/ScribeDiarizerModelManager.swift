// Scribe/Diarization/Portable/ScribeDiarizerModelManager.swift
//
// The speaker-diarization models on the Mac, iPhone and iPad. They are never
// bundled (the apps stay small): the Mac fetches them in the background
// shortly after installation, iPhone / iPad on first use; both can manage
// them from Settings. They live in Application Support (excluded from
// backups). Download logic and file layout: ScribeDiarizerModelFiles.swift.

import Foundation
import Observation

@MainActor
@Observable
final class ScribeDiarizerModelManager {

    enum State: Equatable {
        case notInstalled
        /// 0…1.
        case downloading(Double)
        /// Bytes on disk.
        case installed(Int64)
        case failed(String)
    }

    static let shared = ScribeDiarizerModelManager(
        layout: ScribeDiarizerModelLayout.downloaded(applicationSupport: URL.applicationSupportDirectory)
    )

    /// Whether downloads may use cellular / expensive networks: the iPhone /
    /// iPad Wi‑Fi-only setting; always on the Mac.
    static var allowsCellular: Bool {
        #if os(iOS)
        !IOSDiarizationSettings.wifiOnly
        #else
        true
        #endif
    }

    let layout: ScribeDiarizerModelLayout
    private(set) var state: State = .notInstalled
    /// The last failure was "no (allowed) network", so a retry needs
    /// connectivity rather than a fix.
    private(set) var lastFailureWasConnectivity = false

    @ObservationIgnored private var downloadTask: Task<Bool, Never>?
    /// Bumped per download so a cancelled one finishing late can't clobber
    /// the state of the next.
    @ObservationIgnored private var downloadGeneration = 0

    init(layout: ScribeDiarizerModelLayout) {
        self.layout = layout
        refresh()
    }

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    var isDownloading: Bool { downloadTask != nil }

    /// Re-reads the disk (not while a download runs).
    func refresh() {
        guard downloadTask == nil else { return }
        if layout.isInstalledOnDisk() {
            state = .installed(ScribeDiarizerModelStorage.installedBytes(layout))
        } else if case .failed = state {
            // Keep showing the error until the next attempt.
        } else {
            state = .notInstalled
        }
    }

    /// Starts the download from Settings (no-op when installed or running).
    func download() {
        guard downloadTask == nil, !layout.isInstalledOnDisk() else {
            refresh()
            return
        }
        _ = startDownload()
    }

    /// Installs the models if needed (joining a running download). Returns
    /// whether they're installed afterwards.
    func ensureInstalled() async -> Bool {
        if layout.isInstalledOnDisk() {
            refresh()
            return true
        }
        let task = downloadTask ?? startDownload()
        return await task.value
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Deletes the downloaded models.
    func delete() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration += 1
        do {
            try ScribeDiarizerModelStorage.remove(layout)
        } catch {
            Log.speech.error("Couldn't delete the speaker models: \(error.localizedDescription, privacy: .public)")
        }
        state = .notInstalled
        refresh()
    }

    // MARK: - Private

    private func startDownload() -> Task<Bool, Never> {
        let layout = self.layout
        let allowsCellular = Self.allowsCellular
        prepareRoot()
        state = .downloading(0)
        lastFailureWasConnectivity = false
        downloadGeneration += 1
        let generation = downloadGeneration
        let task = Task { @MainActor () -> Bool in
            let session = ScribeDiarizerModelDownloader.makeSession(allowsCellular: allowsCellular)
            // One session per download: release it when done.
            defer { session.finishTasksAndInvalidate() }
            let downloader = ScribeDiarizerModelDownloader(session: session)
            do {
                let bytes = try await downloader.install(into: layout, progress: Self.makeProgressHandler())
                Log.speech.info("Speaker models downloaded (\(bytes) bytes).")
                guard self.downloadGeneration == generation else { return layout.isInstalledOnDisk() }
                self.downloadTask = nil
                self.state = .installed(ScribeDiarizerModelStorage.installedBytes(layout))
                return true
            } catch {
                guard self.downloadGeneration == generation else { return false }
                self.downloadTask = nil
                if error is CancellationError || Task.isCancelled {
                    self.state = .notInstalled
                } else {
                    let connectivity = Self.isConnectivityError(error)
                    self.lastFailureWasConnectivity = connectivity
                    self.state = .failed(Self.describe(error, connectivity: connectivity, allowsCellular: allowsCellular))
                    Log.speech.error("Speaker model download failed: \(error.localizedDescription, privacy: .public)")
                }
                return false
            }
        }
        downloadTask = task
        return task
    }

    /// Creates the models root and keeps it (and the staging folder inside
    /// it) out of backups — the files can always be downloaded again.
    private func prepareRoot() {
        do {
            try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
            try ScribeDiarizerModelStorage.excludeFromBackup(layout.root)
        } catch {
            Log.speech.error("Couldn't prepare the speaker model folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate func updateProgress(_ value: Double) {
        guard case .downloading = state else { return }
        state = .downloading(value)
    }

    /// Built outside the main actor: the downloader calls it from its own
    /// executor.
    nonisolated private static func makeProgressHandler() -> @Sendable (Double) -> Void {
        { value in
            Task { @MainActor in
                ScribeDiarizerModelManager.shared.updateProgress(value)
            }
        }
    }

    nonisolated private static func isConnectivityError(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        if urlError.networkUnavailableReason != nil { return true }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    nonisolated private static func describe(_ error: any Error, connectivity: Bool, allowsCellular: Bool) -> String {
        if connectivity {
            return allowsCellular
                ? "No internet connection. The speaker model downloads when you're back online."
                : "Waiting for Wi‑Fi to download the speaker model."
        }
        return error.localizedDescription
    }
}
