import XCTest
@testable import Scribe

final class ScribeDiagnosticsRotationTests: XCTestCase {

    private func file(_ name: String, _ kind: ScribeDiagnosticsKind, _ offset: TimeInterval) -> ScribeDiagnosticsFile {
        ScribeDiagnosticsFile(name: name, kind: kind, createdAt: Date(timeIntervalSince1970: 1_000_000 + offset))
    }

    func testFileNameIsSortableColonFreeAndRoundTripsKind() {
        let date = Date(timeIntervalSince1970: 1_791_620_100) // 2026-10-10T08:15:00Z
        let name = ScribeDiagnosticsRotation.fileName(kind: .diagnostic, date: date, uniquifier: "1a2b3c4d")
        XCTAssertEqual(name, "2026-10-10T08-15-00Z-diagnostic-1a2b3c4d.json")
        XCTAssertFalse(name.contains(":"))
        XCTAssertEqual(ScribeDiagnosticsRotation.kind(ofFileName: name), .diagnostic)

        let metric = ScribeDiagnosticsRotation.fileName(kind: .metric, date: date, uniquifier: "ffff0000")
        XCTAssertEqual(ScribeDiagnosticsRotation.kind(ofFileName: metric), .metric)

        XCTAssertNil(ScribeDiagnosticsRotation.kind(ofFileName: ".DS_Store"))
        XCTAssertNil(ScribeDiagnosticsRotation.kind(ofFileName: "notes.json"))
        XCTAssertNil(ScribeDiagnosticsRotation.kind(ofFileName: "2026-10-10T08-15-00Z-diagnostic.txt"))
    }

    func testNothingRemovedAtOrUnderLimit() {
        let files = (0..<20).map { file("d\($0)", .diagnostic, TimeInterval($0)) }
        XCTAssertEqual(ScribeDiagnosticsRotation.filesToRemove(files, limit: 20), [])
        XCTAssertEqual(ScribeDiagnosticsRotation.filesToRemove([], limit: 20), [])
    }

    func testOldestDiagnosticsRemovedFirst() {
        let files = (0..<23).map { file("d\($0)", .diagnostic, TimeInterval($0)) }.shuffled()
        XCTAssertEqual(ScribeDiagnosticsRotation.filesToRemove(files, limit: 20), ["d0", "d1", "d2"])
    }

    func testMetricsAreRemovedBeforeDiagnostics() {
        var files = (0..<18).map { file("d\($0)", .diagnostic, TimeInterval($0)) }
        // Metric summaries newer than every diagnostic still go first.
        files += (0..<5).map { file("m\($0)", .metric, 100 + TimeInterval($0)) }
        let removed = ScribeDiagnosticsRotation.filesToRemove(files, limit: 20)
        XCTAssertEqual(removed, ["m0", "m1", "m2"])
    }

    func testFallsBackToDiagnosticsWhenMetricsRunOut() {
        var files = (0..<21).map { file("d\($0)", .diagnostic, TimeInterval($0)) }
        files.append(file("m0", .metric, 500))
        XCTAssertEqual(ScribeDiagnosticsRotation.filesToRemove(files, limit: 20), ["m0", "d0"])
    }

    func testDefaultLimitIsTwenty() {
        XCTAssertEqual(ScribeDiagnosticsRotation.maxFiles, 20)
        let files = (0..<21).map { file("d\($0)", .diagnostic, TimeInterval($0)) }
        XCTAssertEqual(ScribeDiagnosticsRotation.filesToRemove(files), ["d0"])
    }

    func testStoreSaveRotatesOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScribeDiagnosticsStore(directory: directory)

        for index in 0..<(ScribeDiagnosticsRotation.maxFiles + 3) {
            try store.save(Data("{\"i\":\(index)}".utf8), kind: .diagnostic, date: Date())
        }
        XCTAssertEqual(store.files().count, ScribeDiagnosticsRotation.maxFiles)

        // Foreign files are left alone and never counted.
        try Data().write(to: directory.appendingPathComponent("README.txt"))
        XCTAssertEqual(store.files().count, ScribeDiagnosticsRotation.maxFiles)

        let exportParent = directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let exported = try store.export(into: exportParent, date: Date())
        let exportedNames = try FileManager.default.contentsOfDirectory(atPath: exported.path)
        XCTAssertEqual(exportedNames.count, ScribeDiagnosticsRotation.maxFiles)

        store.removeAll()
        XCTAssertEqual(store.files().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("README.txt").path))
    }

    func testMaintenanceJobsHaveDistinctIdentifiersAndSaneTolerances() {
        let identifiers = ScribeMaintenanceJob.allCases.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        // Own namespace, so it never collides with the backup activity.
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("com.varij.scribe.maintenance.") })
        for job in ScribeMaintenanceJob.allCases {
            XCTAssertGreaterThanOrEqual(job.interval, 60 * 60, "\(job) runs too often")
            XCTAssertLessThan(job.tolerance, job.interval)
        }
    }
}
