// ScribeiOS/Diarization/IOSDiarizationModelManager.swift
//
// The speaker-diarization models on iPhone / iPad. Unlike the Mac they are not
// bundled (the app stays small); they download on first use — or from
// Settings › Speakers — into Application Support, excluded from iCloud /
// device backups, Wi‑Fi only unless the user allows cellular. The download
// logic and file layout are the Mac's portable ones
// (Scribe/Diarization/Portable/ScribeDiarizerModelFiles.swift).

import Foundation
import Observation

/// UserDefaults keys and readers for speaker separation on iPhone / iPad.
enum IOSDiarizationSettings {
    nonisolated static let enabledKey = "ios.diarization.enabled"
    nonisolated static let wifiOnlyKey = "ios.diarization.wifiOnly"
    nonisolated static let suggestNamesKey = "ios.diarization.suggestNames"

    static var isEnabled: Bool { bool(enabledKey, default: true) }
    static var wifiOnly: Bool { bool(wifiOnlyKey, default: true) }
    static var suggestNames: Bool { bool(suggestNamesKey, default: true) }

    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

@MainActor
@Observable
final class IOSDiarizationModelManager {

    enum State: Equatable {
        case notInstalled
        /// 0…1.
        case downloading(Double)
        /// Bytes on disk.
        case installed(Int64)
        case failed(String)
    }

    static let shared = IOSDiarizationModelManager(
        layout: ScribeDiarizerModelLayout.downloaded(applicationSupport: URL.applicationSupportDirectory)
    )

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
        let allowsCellular = !IOSDiarizationSettings.wifiOnly
        prepareRoot()
        state = .downloading(0)
        lastFailureWasConnectivity = false
        downloadGeneration += 1
        let generation = downloadGeneration
        let task = Task { @MainActor () -> Bool in
            let downloader = ScribeDiarizerModelDownloader(
                session: ScribeDiarizerModelDownloader.makeSession(allowsCellular: allowsCellular)
            )
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
                IOSDiarizationModelManager.shared.updateProgress(value)
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
