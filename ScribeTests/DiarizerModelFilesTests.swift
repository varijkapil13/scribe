import XCTest
@testable import Scribe

/// The portable diarizer-model layer the iPhone / iPad app downloads with:
/// file filter, listing parser, install check, size / backup helpers and
/// the staged downloader (against a stubbed URL protocol).
final class DiarizerModelFilesTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizerModelFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        StubModelResponses.shared.reset()
    }

    // MARK: - Repository

    func testWantedFilesMatchTheFetchScript() {
        let R = ScribeDiarizerModelRepository.self
        XCTAssertTrue(R.isWanted(path: "plda-parameters.json"))
        XCTAssertTrue(R.isWanted(path: "Segmentation.mlmodelc/coremldata.bin"))
        XCTAssertTrue(R.isWanted(path: "Embedding.mlmodelc/weights/weight.bin"))
        XCTAssertTrue(R.isWanted(path: "FBank.mlmodelc/model.mil"))
        XCTAssertTrue(R.isWanted(path: "PldaRho.mlmodelc/metadata.json"))
        XCTAssertFalse(R.isWanted(path: "README.md"))
        XCTAssertFalse(R.isWanted(path: "Segmentation.mlmodelc"), "the bundle folder itself isn't a file")
        XCTAssertFalse(R.isWanted(path: "Other.mlmodelc/model.mil"))
        XCTAssertFalse(R.isWanted(path: "nested/plda-parameters.json"))
    }

    func testURLsArePinnedToTheRevision() throws {
        let R = ScribeDiarizerModelRepository.self
        let tree = try XCTUnwrap(R.treeURL)
        XCTAssertTrue(tree.absoluteString.contains(R.revision))
        XCTAssertTrue(tree.absoluteString.contains("recursive=1"))
        let file = try XCTUnwrap(R.fileURL(path: "Embedding.mlmodelc/weights/weight.bin"))
        XCTAssertEqual(file.absoluteString,
                       "https://huggingface.co/\(R.repo)/resolve/\(R.revision)/Embedding.mlmodelc/weights/weight.bin")
    }

    // MARK: - Manifest

    func testListingKeepsWantedFilesWithLFSSizes() throws {
        let json = """
        [
          {"type": "directory", "path": "Embedding.mlmodelc"},
          {"type": "file", "path": "Embedding.mlmodelc/weights/weight.bin", "size": 134,
           "lfs": {"oid": "x", "size": 13000000, "pointerSize": 134}},
          {"type": "file", "path": "Segmentation.mlmodelc/model.mil", "size": 2000},
          {"type": "file", "path": "plda-parameters.json", "size": 300},
          {"type": "file", "path": "README.md", "size": 10},
          {"type": "file", "path": "FBank.mlmodelc/../../etc/passwd", "size": 1}
        ]
        """
        let files = try ScribeDiarizerModelManifest.files(fromTreeListing: Data(json.utf8))
        XCTAssertEqual(files, [
            ScribeDiarizerModelFile(path: "Embedding.mlmodelc/weights/weight.bin", size: 13_000_000),
            ScribeDiarizerModelFile(path: "Segmentation.mlmodelc/model.mil", size: 2_000),
            ScribeDiarizerModelFile(path: "plda-parameters.json", size: 300),
        ])
        XCTAssertEqual(ScribeDiarizerModelManifest.totalBytes(files), 13_002_300)
        XCTAssertFalse(ScribeDiarizerModelManifest.isComplete(files), "FBank and PldaRho are missing")
        XCTAssertTrue(ScribeDiarizerModelManifest.isComplete(Self.completeFiles))
    }

    func testListingRejectsGarbage() {
        XCTAssertThrowsError(try ScribeDiarizerModelManifest.files(fromTreeListing: Data("{}".utf8)))
        XCTAssertThrowsError(try ScribeDiarizerModelManifest.files(fromTreeListing: Data("nope".utf8)))
    }

    func testSafeRelativePaths() {
        let M = ScribeDiarizerModelManifest.self
        XCTAssertTrue(M.isSafeRelativePath("a/b.bin"))
        XCTAssertFalse(M.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(M.isSafeRelativePath("a/../b"))
        XCTAssertFalse(M.isSafeRelativePath("a//b"))
        XCTAssertFalse(M.isSafeRelativePath("./a"))
        XCTAssertFalse(M.isSafeRelativePath(""))
    }

    // MARK: - Layout

    func testDownloadedLayoutLivesInApplicationSupport() {
        let support = URL(fileURLWithPath: "/tmp/Support", isDirectory: true)
        let layout = ScribeDiarizerModelLayout.downloaded(applicationSupport: support)
        XCTAssertEqual(layout.root.path, "/tmp/Support/Scribe/DiarizerModels")
        XCTAssertEqual(layout.repoDirectory.lastPathComponent, ScribeDiarizerModelRepository.folderName)
        XCTAssertEqual(layout.markerURL.lastPathComponent, ".fluidaudio-revision")
    }

    func testInstallCheckNeedsMarkerAndEveryModel() {
        let layout = ScribeDiarizerModelLayout(root: URL(fileURLWithPath: "/m", isDirectory: true))
        let required = (ScribeDiarizerModelRepository.modelBundleNames + [ScribeDiarizerModelRepository.parametersFileName])
            .map { layout.repoDirectory.appendingPathComponent($0).path }
        let revision = ScribeDiarizerModelRepository.revision

        XCTAssertTrue(layout.isInstalled(fileExists: { required.contains($0) }, readMarker: { _ in revision + "\n" }))
        XCTAssertFalse(layout.isInstalled(fileExists: { required.contains($0) }, readMarker: { _ in "main" }),
                       "a different revision is not installed")
        XCTAssertFalse(layout.isInstalled(fileExists: { required.contains($0) }, readMarker: { _ in nil }))
        XCTAssertFalse(layout.isInstalled(fileExists: { $0 != required[0] && required.contains($0) },
                                          readMarker: { _ in revision }))
    }

    // MARK: - Storage

    func testSizeLabelAndInstalledBytes() throws {
        XCTAssertTrue(ScribeDiarizerModelStorage.sizeLabel(bytes: 22_000_000).contains("MB"))
        XCTAssertFalse(ScribeDiarizerModelStorage.sizeLabel(bytes: -5).isEmpty)

        let layout = ScribeDiarizerModelLayout(root: tempRoot)
        XCTAssertEqual(ScribeDiarizerModelStorage.installedBytes(layout), 0)
        try FileManager.default.createDirectory(at: layout.repoDirectory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: layout.repoDirectory.appendingPathComponent("a.bin"))
        XCTAssertGreaterThanOrEqual(ScribeDiarizerModelStorage.installedBytes(layout), 10_000)

        try ScribeDiarizerModelStorage.remove(layout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.repoDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.root.path), "the root stays")
        XCTAssertNoThrow(try ScribeDiarizerModelStorage.remove(layout), "removing nothing is fine")
    }

    func testExcludeFromBackup() throws {
        try ScribeDiarizerModelStorage.excludeFromBackup(tempRoot)
        let values = try tempRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Downloader

    func testDownloaderInstallsAtomicallyWithProgress() async throws {
        stubCompleteRepository()
        let layout = ScribeDiarizerModelLayout(root: tempRoot.appendingPathComponent("Models", isDirectory: true))
        let progress = DiarizerProgressRecorder()
        let downloader = ScribeDiarizerModelDownloader(session: Self.stubSession())

        let bytes = try await downloader.install(into: layout, progress: { progress.record($0) })

        XCTAssertEqual(bytes, ScribeDiarizerModelManifest.totalBytes(Self.completeFiles))
        XCTAssertTrue(layout.isInstalledOnDisk())
        let marker = try String(contentsOf: layout.markerURL, encoding: .utf8)
        XCTAssertEqual(marker, ScribeDiarizerModelRepository.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.repoDirectory.appendingPathComponent("README.md").path))
        let parameters = try Data(contentsOf: layout.repoDirectory.appendingPathComponent("plda-parameters.json"))
        XCTAssertEqual(String(decoding: parameters, as: UTF8.self), "file:plda-parameters.json")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.root.path),
                       [ScribeDiarizerModelRepository.folderName], "no staging folder left behind")
        let values = progress.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "progress only moves forward")
    }

    func testDownloaderFailureLeavesNothingInstalled() async throws {
        stubCompleteRepository()
        if let url = ScribeDiarizerModelRepository.fileURL(path: "FBank.mlmodelc/model.mil") {
            StubModelResponses.shared.set(url, status: 404, body: Data())
        }
        let layout = ScribeDiarizerModelLayout(root: tempRoot.appendingPathComponent("Models", isDirectory: true))
        let downloader = ScribeDiarizerModelDownloader(session: Self.stubSession())
        do {
            try await downloader.install(into: layout, progress: { _ in })
            XCTFail("expected the 404 to fail the install")
        } catch let error as ScribeDiarizerDownloadError {
            XCTAssertEqual(error, .badResponse(404))
        }
        XCTAssertFalse(layout.isInstalledOnDisk())
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.repoDirectory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.root.path), [])
    }

    // MARK: - Helpers

    static let completeFiles: [ScribeDiarizerModelFile] = [
        ScribeDiarizerModelFile(path: "Embedding.mlmodelc/weights/weight.bin", size: 40),
        ScribeDiarizerModelFile(path: "FBank.mlmodelc/model.mil", size: 30),
        ScribeDiarizerModelFile(path: "PldaRho.mlmodelc/model.mil", size: 20),
        ScribeDiarizerModelFile(path: "Segmentation.mlmodelc/model.mil", size: 10),
        ScribeDiarizerModelFile(path: "plda-parameters.json", size: 5),
    ]

    private func stubCompleteRepository() {
        let stubs = StubModelResponses.shared
        stubs.reset()
        var entries = Self.completeFiles.map { #"{"type": "file", "path": "\#($0.path)", "size": \#($0.size)}"# }
        entries.append(#"{"type": "file", "path": "README.md", "size": 3}"#)
        if let tree = ScribeDiarizerModelRepository.treeURL {
            stubs.set(tree, status: 200, body: Data(("[" + entries.joined(separator: ",") + "]").utf8))
        }
        for file in Self.completeFiles + [ScribeDiarizerModelFile(path: "README.md", size: 3)] {
            if let url = ScribeDiarizerModelRepository.fileURL(path: file.path) {
                stubs.set(url, status: 200, body: Data("file:\(file.path)".utf8))
            }
        }
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubModelURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Canned responses by absolute URL, shared with the URL protocol.
final class StubModelResponses: @unchecked Sendable {
    static let shared = StubModelResponses()

    private let lock = NSLock()
    private var responses: [String: (Int, Data)] = [:]

    func set(_ url: URL, status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses[url.absoluteString] = (status, body)
    }

    func response(for url: URL) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        return responses[url.absoluteString] ?? (404, Data())
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll()
    }
}

final class StubModelURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, body) = StubModelResponses.shared.response(for: url)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Collects progress callbacks from the downloader's executor.
final class DiarizerProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
