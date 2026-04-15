import Foundation
import Combine

/// Manages downloading, storage, and selection of Whisper models.
final class ModelManager: ObservableObject {

    // MARK: - WhisperModel

    /// Available Whisper model variants.
    enum WhisperModel: String, CaseIterable, Identifiable {
        case medium = "ggml-medium"
        case largev3Turbo = "ggml-large-v3-turbo"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .medium:
                return "Medium (~1.5 GB)"
            case .largev3Turbo:
                return "Large v3 Turbo (~3 GB)"
            }
        }

        var fileName: String {
            rawValue + ".bin"
        }

        var downloadURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
        }

        var estimatedSize: String {
            switch self {
            case .medium:
                return "~1.5 GB"
            case .largev3Turbo:
                return "~3 GB"
            }
        }
    }

    // MARK: - Published Properties

    /// All available model variants.
    @Published var availableModels: [WhisperModel] = WhisperModel.allCases

    /// Set of models that have been downloaded to disk.
    @Published var downloadedModels: Set<WhisperModel> = []

    /// The currently selected model (may or may not be downloaded yet).
    @Published var selectedModel: WhisperModel?

    /// Download progress from 0.0 to 1.0.
    @Published var downloadProgress: Double = 0

    /// Whether a download is currently in progress.
    @Published var isDownloading: Bool = false

    /// Human-readable error message from the last failed download.
    @Published var downloadError: String?

    // MARK: - Properties

    /// Directory where model files are stored.
    let modelsDirectory: URL

    /// The active download task, if any.
    private var downloadTask: URLSessionDownloadTask?

    /// Observation token for download progress.
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Initializer

    init() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        modelsDirectory = appSupportURL
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)

        // Ensure the models directory exists.
        try? fileManager.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        // Scan for already-downloaded models.
        scanDownloadedModels()
    }

    // MARK: - Path Helpers

    /// Returns the on-disk URL for a given model.
    func modelPath(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// Whether the given model file exists on disk.
    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }

    /// Returns the file-system path of the selected model, or `nil` if no model
    /// is selected or the selected model has not been downloaded.
    func selectedModelPath() -> String? {
        guard let selected = selectedModel, isModelDownloaded(selected) else {
            return nil
        }
        return modelPath(for: selected).path
    }

    // MARK: - Download

    /// Download a Whisper model from Hugging Face.
    ///
    /// Progress is published to `downloadProgress`. On completion the model is
    /// moved into `modelsDirectory` and `downloadedModels` is updated.
    ///
    /// - Parameter model: The model variant to download.
    func downloadModel(_ model: WhisperModel) async throws {
        // Reset state.
        await MainActor.run {
            self.isDownloading = true
            self.downloadProgress = 0
            self.downloadError = nil
        }

        let destination = modelPath(for: model)

        // If the file already exists, skip the download.
        if FileManager.default.fileExists(atPath: destination.path) {
            await MainActor.run {
                self.downloadedModels.insert(model)
                self.isDownloading = false
                self.downloadProgress = 1.0
            }
            return
        }

        do {
            let fileURL = try await performDownload(url: model.downloadURL)

            // Move the temporary file to the models directory.
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: fileURL, to: destination)

            await MainActor.run {
                self.downloadedModels.insert(model)
                self.isDownloading = false
                self.downloadProgress = 1.0
            }
        } catch {
            await MainActor.run {
                self.downloadError = error.localizedDescription
                self.isDownloading = false
                self.downloadProgress = 0
            }
            throw error
        }
    }

    /// Cancel any in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation?.invalidate()
        progressObservation = nil

        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadProgress = 0
        }
    }

    /// Delete a downloaded model from disk.
    ///
    /// - Parameter model: The model variant to remove.
    func deleteModel(_ model: WhisperModel) throws {
        let path = modelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        downloadedModels.remove(model)

        // Clear selection if the deleted model was selected.
        if selectedModel == model {
            selectedModel = nil
        }
    }

    // MARK: - Private Helpers

    /// Scan the models directory and populate `downloadedModels`.
    private func scanDownloadedModels() {
        var found: Set<WhisperModel> = []
        for model in WhisperModel.allCases where isModelDownloaded(model) {
            found.insert(model)
        }
        downloadedModels = found

        // Auto-select the first downloaded model if nothing is selected.
        if selectedModel == nil, let first = WhisperModel.allCases.first(where: { found.contains($0) }) {
            selectedModel = first
        }
    }

    /// Perform the actual URLSession download, tracking progress via KVO.
    private func performDownload(url: URL) async throws -> URL {
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url)
        self.downloadTask = task

        // Observe fractionCompleted on the task's progress.
        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, change in
            guard let fraction = change.newValue else { return }
            DispatchQueue.main.async {
                self?.downloadProgress = fraction
            }
        }
        self.progressObservation = observation

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(continuation: continuation)
            // We need to recreate the task with a delegate, since URLSessionDownloadTask
            // requires a delegate to receive the file URL on completion.
            self.downloadTask?.cancel()

            let delegateSession = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let delegateTask = delegateSession.downloadTask(with: url)

            // Re-observe the new task's progress.
            self.progressObservation?.invalidate()
            self.progressObservation = delegateTask.progress.observe(
                \.fractionCompleted,
                options: [.new]
            ) { [weak self] _, change in
                guard let fraction = change.newValue else { return }
                DispatchQueue.main.async {
                    self?.downloadProgress = fraction
                }
            }

            self.downloadTask = delegateTask
            delegateTask.resume()
        }
    }
}

// MARK: - WhisperModel Hashable

extension ModelManager.WhisperModel: Hashable {}

// MARK: - DownloadDelegate

/// Minimal URLSession download delegate that bridges to an async continuation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private var continuation: CheckedContinuation<URL, Error>?

    init(continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` is temporary; copy it so it survives delegate return.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            continuation?.resume(returning: tempURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Progress is tracked via KVO on the task's progress object,
        // but we update here as well for environments where KVO may lag.
        // No-op: handled by the KVO observation in ModelManager.
    }
}
