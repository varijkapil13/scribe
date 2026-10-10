import XCTest
@testable import Scribe

final class ScribeBackupManifestTests: XCTestCase {

    private func makeManifest(
        formatVersion: Int = ScribeBackupManifest.currentFormatVersion,
        migrations: [String] = ["v1", "v2"]
    ) -> ScribeBackupManifest {
        ScribeBackupManifest(
            formatVersion: formatVersion,
            appVersion: "1.4",
            appBuild: "42",
            // Whole seconds: ISO 8601 encoding drops fractions.
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isAutomatic: false,
            counts: ScribeBackupManifest.Counts(
                notes: 3, attachments: 2, vaultFiles: 6, sessions: 4, tasks: 5, settings: 7
            ),
            schemaMigrations: migrations,
            supportFiles: ["vocabulary.md"],
            skippedSymlinks: 0
        )
    }

    func testEncodeDecodeRoundTrips() throws {
        let manifest = makeManifest()
        let data = try ScribeBackupManifest.encode(manifest)
        XCTAssertEqual(try ScribeBackupManifest.decode(data), manifest)
    }

    func testEncodedJSONUsesStableKeysAndISODates() throws {
        let data = try ScribeBackupManifest.encode(makeManifest())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["createdAt"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(object["schemaMigrations"] as? [String], ["v1", "v2"])
        let counts = try XCTUnwrap(object["counts"] as? [String: Any])
        XCTAssertEqual(counts["sessions"] as? Int, 4)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try ScribeBackupManifest.decode(Data("{\"formatVersion\": 1}".utf8)))
        XCTAssertThrowsError(try ScribeBackupManifest.decode(Data("not json".utf8)))
    }

    func testValidManifestHasNoIssues() {
        let issues = makeManifest().validationIssues(knownMigrations: ["v1", "v2", "v3"])
        XCTAssertEqual(issues, [])
    }

    func testNewerFormatIsRejected() {
        let issues = makeManifest(formatVersion: ScribeBackupManifest.currentFormatVersion + 1)
            .validationIssues(knownMigrations: ["v1", "v2"])
        XCTAssertEqual(issues, [.unsupportedFormat(found: 2, supported: 1)])
    }

    func testZeroFormatIsRejected() {
        let issues = makeManifest(formatVersion: 0).validationIssues(knownMigrations: ["v1", "v2"])
        XCTAssertEqual(issues.first, .unsupportedFormat(found: 0, supported: 1))
    }

    func testUnknownMigrationsMeanNewerSchema() {
        let issues = makeManifest(migrations: ["v1", "v9_future", "v8_future"])
            .validationIssues(knownMigrations: ["v1", "v2"])
        XCTAssertEqual(issues, [.newerDatabaseSchema(unknownMigrations: ["v8_future", "v9_future"])])
    }

    func testDatabaseMigrationsOverrideTheManifest() {
        // The manifest claims an old schema but the database file is newer.
        let issues = makeManifest(migrations: ["v1"])
            .validationIssues(knownMigrations: ["v1"], databaseMigrations: ["v1", "v99"])
        XCTAssertEqual(issues, [.newerDatabaseSchema(unknownMigrations: ["v99"])])
    }

    func testEmptySchemaIsRejected() {
        let issues = makeManifest(migrations: []).validationIssues(knownMigrations: ["v1"])
        XCTAssertEqual(issues, [.missingDatabaseSchema])
    }

    func testIssuesHaveUserFacingMessages() {
        let all: [ScribeBackupValidationIssue] = [
            .unsupportedFormat(found: 2, supported: 1),
            .newerDatabaseSchema(unknownMigrations: ["x"]),
            .missingDatabaseSchema,
            .missingFile("Vault"),
            .unsafeArchiveEntries(["../x"]),
            .damagedDatabase("bad"),
        ]
        for issue in all {
            XCTAssertFalse(issue.message.isEmpty)
        }
    }

    func testSummaryTextMentionsCounts() {
        let text = makeManifest().summaryText(formattedDate: "Jan 15")
        XCTAssertTrue(text.contains("Jan 15"))
        XCTAssertTrue(text.contains("3 notes"))
        XCTAssertTrue(text.contains("2 attachments"))
        XCTAssertTrue(text.contains("4 transcripts"))
        XCTAssertTrue(text.contains("5 tasks"))
        XCTAssertTrue(text.contains("7 settings"))
    }
}
