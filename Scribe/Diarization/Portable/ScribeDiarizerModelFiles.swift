import Foundation

// MARK: - Speaker-diarization model files (portable)
//
// The Core ML models FluidAudio's offline diarizer loads, where they live on
// disk and how to fetch them. Foundation only: compiled into the macOS app
// (and its `swift test` target) and into the iPhone / iPad app. Neither app
// bundles the models; both download them (ScribeDiarizerModelManager).
//
// The pinned repository / revision must match what the FluidAudio version in
// Package.swift / project.yml expects. Bump them together.

/// The pinned Hugging Face repository the diarizer models come from.
enum ScribeDiarizerModelRepository {

    /// `ModelNames.Repo.diarizer` in FluidAudio.
    nonisolated static let repo = "FluidInference/speaker-diarization-coreml"
    /// What FluidAudio 0.17.7 expects (`ModelNames.Repo.diarizer.revision`).
    nonisolated static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    /// FluidAudio's folder name for the repository inside a models root.
    nonisolated static let folderName = "speaker-diarization-coreml"
    /// FluidAudio treats a repo folder holding this marker (containing the
    /// pinned revision) as a complete cache and never re-downloads it.
    nonisolated static let revisionMarkerName = ".fluidaudio-revision"
    /// The compiled model bundles `OfflineDiarizerModels.load` reads.
    nonisolated static let modelBundleNames = [
        "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc",
    ]
    /// The PLDA parameters file, at the repository root.
    nonisolated static let parametersFileName = "plda-parameters.json"
    /// Shown before the first download (the real size is read from the
    /// listing / the disk afterwards).
    nonisolated static let approximateDownloadBytes: Int64 = 22_000_000

    /// Whether a repository file is one the offline diarizer needs.
    nonisolated static func isWanted(path: String) -> Bool {
        if path == parametersFileName { return true }
        guard let first = path.split(separator: "/", omittingEmptySubsequences: false).first,
              path.contains("/") else { return false }
        return modelBundleNames.contains(String(first))
    }

    /// The recursive file listing for the pinned revision.
    nonisolated static var treeURL: URL? {
        URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=1")
    }

    /// The download URL of one repository file at the pinned revision.
    nonisolated static func fileURL(path: String) -> URL? {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encoded)")
    }
}

/// One file of the model repository.
struct ScribeDiarizerModelFile: Equatable, Sendable {
    /// Path relative to the repository root ("Embedding.mlmodelc/weights/weight.bin").
    let path: String
    /// Size in bytes (0 when the listing didn't say).
    let size: Int64
}

/// Parses the Hugging Face tree listing.
enum ScribeDiarizerModelManifest {

    /// The wanted files from a `/api/models/<repo>/tree/<rev>?recursive=1`
    /// response, sorted by path. Directories, unwanted files and unsafe
    /// paths are dropped.
    nonisolated static func files(fromTreeListing data: Data) throws -> [ScribeDiarizerModelFile] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScribeDiarizerDownloadError.unreadableListing
        }
        var files: [ScribeDiarizerModelFile] = []
        for entry in entries {
            guard (entry["type"] as? String) == "file",
                  let path = entry["path"] as? String,
                  isSafeRelativePath(path),
                  ScribeDiarizerModelRepository.isWanted(path: path) else { continue }
            files.append(ScribeDiarizerModelFile(path: path, size: size(of: entry)))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// True when `files` covers every model bundle and the parameters file.
    nonisolated static func isComplete(_ files: [ScribeDiarizerModelFile]) -> Bool {
        let paths = files.map(\.path)
        guard paths.contains(ScribeDiarizerModelRepository.parametersFileName) else { return false }
        return ScribeDiarizerModelRepository.modelBundleNames.allSatisfy { bundle in
            paths.contains { $0.hasPrefix(bundle + "/") }
        }
    }

    nonisolated static func totalBytes(_ files: [ScribeDiarizerModelFile]) -> Int64 {
        files.reduce(0) { $0 + max(0, $1.size) }
    }

    /// A relative path that stays inside the destination folder.
    nonisolated static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The file size: LFS files report it under `lfs.size`.
    private nonisolated static func size(of entry: [String: Any]) -> Int64 {
        if let lfs = entry["lfs"] as? [String: Any], let size = (lfs["size"] as? NSNumber)?.int64Value {
            return size
        }
        return (entry["size"] as? NSNumber)?.int64Value ?? 0
    }
}

/// Where a models root keeps its files. `root` is what FluidAudio's
/// `prepareModels(directory:)` takes: the parent of the repository folder.
struct ScribeDiarizerModelLayout: Equatable, Sendable {
    let root: URL

    nonisolated init(root: URL) {
        self.root = root
    }

    /// `<Application Support>/Scribe/DiarizerModels` — the download location
    /// on the Mac, iPhone and iPad.
    nonisolated static func downloaded(applicationSupport: URL) -> ScribeDiarizerModelLayout {
        ScribeDiarizerModelLayout(root: applicationSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("DiarizerModels", isDirectory: true))
    }

    nonisolated var repoDirectory: URL {
        root.appendingPathComponent(ScribeDiarizerModelRepository.folderName, isDirectory: true)
    }

    nonisolated var markerURL: URL {
        repoDirectory.appendingPathComponent(ScribeDiarizerModelRepository.revisionMarkerName, isDirectory: false)
    }

    /// Complete for the pinned revision: the marker names it and every model
    /// bundle and the parameters file are present.
    nonisolated func isInstalled(fileExists: (String) -> Bool, readMarker: (URL) -> String?) -> Bool {
        guard let marker = readMarker(markerURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              marker == ScribeDiarizerModelRepository.revision else { return false }
        let required = ScribeDiarizerModelRepository.modelBundleNames + [ScribeDiarizerModelRepository.parametersFileName]
        return required.allSatisfy { fileExists(repoDirectory.appendingPathComponent($0).path) }
    }

    /// ``isInstalled(fileExists:readMarker:)`` against the real disk.
    nonisolated func isInstalledOnDisk() -> Bool {
        isInstalled(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readMarker: { url in (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }
        )
    }
}

/// Size and backup helpers for the models folder.
enum ScribeDiarizerModelStorage {

    /// "22 MB" for a byte count.
    nonisolated static func sizeLabel(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// Bytes used by the installed models (0 when there are none).
    nonisolated static func installedBytes(_ layout: ScribeDiarizerModelLayout) -> Int64 {
        SessionAudioStorage.diskUsage(of: layout.repoDirectory)
    }

    /// Keeps a re-downloadable folder out of iCloud / device backups.
    nonisolated static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }

    /// Removes the installed models (the root folder itself stays).
    nonisolated static func remove(_ layout: ScribeDiarizerModelLayout) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: layout.repoDirectory.path) else { return }
        try fileManager.removeItem(at: layout.repoDirectory)
    }
}

enum ScribeDiarizerDownloadError: LocalizedError, Equatable {
    case unreadableListing
    case incompleteListing
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableListing, .incompleteListing:
            return "The speaker model listing couldn't be read. Try again later."
        case .badResponse(let status):
            return "The speaker model download failed (HTTP \(status)). Try again later."
        }
    }
}

/// Downloads the pinned model files into a ``ScribeDiarizerModelLayout``.
///
/// Files land in a hidden staging folder first and are moved into place only
/// once every file arrived, so an interrupted download never leaves a
/// half-installed repository that FluidAudio would try to load. Cancelling
/// the calling task cancels the transfer.
struct ScribeDiarizerModelDownloader: Sendable {
    let session: URLSession

    nonisolated init(session: URLSession) {
        self.session = session
    }

    /// A session for model downloads. `allowsCellular == false` keeps the
    /// download on Wi‑Fi (no cellular, no Personal Hotspot / expensive paths).
    nonisolated static func makeSession(allowsCellular: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }

    /// Installs the models. `progress` receives 0…1 as files complete.
    /// Returns the downloaded byte count.
    @discardableResult
    nonisolated func install(
        into layout: ScribeDiarizerModelLayout,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        guard let treeURL = ScribeDiarizerModelRepository.treeURL else {
            throw ScribeDiarizerDownloadError.unreadableListing
        }
        let (listing, listingResponse) = try await session.data(from: treeURL)
        try Self.check(listingResponse)
        let files = try ScribeDiarizerModelManifest.files(fromTreeListing: listing)
        guard ScribeDiarizerModelManifest.isComplete(files) else {
            throw ScribeDiarizerDownloadError.incompleteListing
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let staging = layout.root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        let stagedRepo = staging.appendingPathComponent(ScribeDiarizerModelRepository.folderName, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let total = max(ScribeDiarizerModelManifest.totalBytes(files), 1)
        var completed: Int64 = 0
        progress(0)
        for file in files {
            try Task.checkCancellation()
            guard let url = ScribeDiarizerModelRepository.fileURL(path: file.path) else {
                throw ScribeDiarizerDownloadError.unreadableListing
            }
            let (temporary, response) = try await session.download(from: url)
            try Self.check(response)
            let destination = stagedRepo.appendingPathComponent(file.path, isDirectory: false)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            completed += max(0, file.size)
            progress(min(1, Double(completed) / Double(total)))
        }
        try Task.checkCancellation()
        try Data(ScribeDiarizerModelRepository.revision.utf8).write(
            to: stagedRepo.appendingPathComponent(ScribeDiarizerModelRepository.revisionMarkerName),
            options: .atomic
        )

        if fileManager.fileExists(atPath: layout.repoDirectory.path) {
            try fileManager.removeItem(at: layout.repoDirectory)
        }
        try fileManager.moveItem(at: stagedRepo, to: layout.repoDirectory)
        progress(1)
        return completed
    }

    private nonisolated static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ScribeDiarizerDownloadError.badResponse(http.statusCode)
        }
    }
}
