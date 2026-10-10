import XCTest
@testable import Scribe

final class ScribeBackupRetentionTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let folder = URL(fileURLWithPath: "/tmp/backups", isDirectory: true)

    private func info(_ name: String, _ seconds: TimeInterval) -> ScribeBackupFileInfo {
        ScribeBackupFileInfo(url: folder.appendingPathComponent(name), createdAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Naming

    func testFileNamesCarryKindAndTimestamp() {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
        XCTAssertEqual(
            ScribeBackupRetention.fileName(for: date, automatic: true, timeZone: utc),
            "Scribe Auto Backup 2027-01-15 080000.scribebackup"
        )
        XCTAssertEqual(
            ScribeBackupRetention.fileName(for: date, automatic: false, timeZone: utc),
            "Scribe Backup 2027-01-15 080000.scribebackup"
        )
    }

    func testAutomaticNameRoundTripsToItsDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_123)
        let name = ScribeBackupRetention.fileName(for: date, automatic: true, timeZone: utc)
        XCTAssertEqual(ScribeBackupRetention.automaticBackupDate(fromFileName: name, timeZone: utc), date)
    }

    func testOnlyAutomaticBackupsAreRecognised() {
        XCTAssertNil(ScribeBackupRetention.automaticBackupDate(fromFileName: "Scribe Backup 2027-01-15 080000.scribebackup", timeZone: utc))
        XCTAssertNil(ScribeBackupRetention.automaticBackupDate(fromFileName: "Scribe Auto Backup 2027-01-15 080000.zip", timeZone: utc))
        XCTAssertNil(ScribeBackupRetention.automaticBackupDate(fromFileName: "Scribe Auto Backup garbage.scribebackup", timeZone: utc))
        XCTAssertNil(ScribeBackupRetention.automaticBackupDate(fromFileName: "notes.md", timeZone: utc))
    }

    func testAutomaticBackupsFiltersFolderListing() {
        let names = [
            "Scribe Auto Backup 2027-01-15 080000.scribebackup",
            "Scribe Backup 2027-01-14 080000.scribebackup",
            ".DS_Store",
            "Scribe Auto Backup 2027-01-16 080000.scribebackup",
        ]
        let found = ScribeBackupRetention.automaticBackups(in: folder, fileNames: names, timeZone: utc)
        XCTAssertEqual(found.map(\.url.lastPathComponent).sorted(), [
            "Scribe Auto Backup 2027-01-15 080000.scribebackup",
            "Scribe Auto Backup 2027-01-16 080000.scribebackup",
        ])
    }

    // MARK: Retention

    func testKeepsNewestN() {
        let backups = [info("a", 100), info("b", 400), info("c", 200), info("d", 300)]
        let deleted = ScribeBackupRetention.backupsToDelete(backups, keeping: 2)
        XCTAssertEqual(deleted.map(\.url.lastPathComponent), ["c", "a"])
    }

    func testNothingDeletedWhenUnderTheLimit() {
        let backups = [info("a", 100), info("b", 200)]
        XCTAssertEqual(ScribeBackupRetention.backupsToDelete(backups, keeping: 2), [])
        XCTAssertEqual(ScribeBackupRetention.backupsToDelete([], keeping: 7), [])
    }

    func testKeepCountNeverDropsBelowOne() {
        let backups = [info("a", 100), info("b", 200), info("c", 300)]
        let deleted = ScribeBackupRetention.backupsToDelete(backups, keeping: 0)
        XCTAssertEqual(deleted.map(\.url.lastPathComponent), ["b", "a"], "The newest backup always survives")
        XCTAssertEqual(ScribeBackupRetention.backupsToDelete(backups, keeping: -5).count, 2)
    }

    func testTiesAreBrokenDeterministically() {
        let backups = [info("a", 100), info("b", 100), info("c", 100)]
        let deleted = ScribeBackupRetention.backupsToDelete(backups, keeping: 1)
        XCTAssertEqual(deleted.map(\.url.lastPathComponent), ["b", "a"])
    }

    func testClampedKeepCount() {
        XCTAssertEqual(ScribeBackupRetention.clampedKeepCount(0), 1)
        XCTAssertEqual(ScribeBackupRetention.clampedKeepCount(7), 7)
        XCTAssertEqual(ScribeBackupRetention.clampedKeepCount(1_000), ScribeBackupRetention.keepCountRange.upperBound)
    }

    // MARK: Schedule

    func testBackupIsDueWithoutAPreviousOne() {
        XCTAssertTrue(ScribeBackupRetention.isBackupDue(lastBackupAt: nil, now: Date()))
    }

    func testBackupIsDueAfterADayAllowingSlack() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3600
        XCTAssertFalse(ScribeBackupRetention.isBackupDue(lastBackupAt: now.addingTimeInterval(-2 * hour), now: now))
        XCTAssertFalse(ScribeBackupRetention.isBackupDue(lastBackupAt: now.addingTimeInterval(-22 * hour), now: now))
        XCTAssertTrue(ScribeBackupRetention.isBackupDue(lastBackupAt: now.addingTimeInterval(-23 * hour), now: now))
        XCTAssertTrue(ScribeBackupRetention.isBackupDue(lastBackupAt: now.addingTimeInterval(-48 * hour), now: now))
    }

    func testFutureLastBackupCountsAsDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ScribeBackupRetention.isBackupDue(lastBackupAt: now.addingTimeInterval(3600), now: now))
    }
}
