import XCTest
@testable import Scribe

/// Exercises only the PURE parts of `ICloudVaultMigrator` — relative-path
/// extraction, destination mapping, and the copy set-difference. The live
/// `enableICloudVault()` / `disableICloudVault()` paths hit iCloud and the
/// real filesystem and are DEVICE-VALIDATION-REQUIRED, so they are out of
/// scope here.
final class ICloudVaultMigratorTests: XCTestCase {

    // MARK: - relativeFilePath

    func testRelativeFilePathStripsRoot() {
        let root = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        let entry = URL(fileURLWithPath: "/vault/Notes/Daily/2026-06-15.md")
        XCTAssertEqual(
            ICloudVaultMigrator.relativeFilePath(of: entry, under: root),
            "Daily/2026-06-15.md"
        )
    }

    func testRelativeFilePathTopLevelFile() {
        let root = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        let entry = URL(fileURLWithPath: "/vault/Notes/Meeting.md")
        XCTAssertEqual(
            ICloudVaultMigrator.relativeFilePath(of: entry, under: root),
            "Meeting.md"
        )
    }

    func testRelativeFilePathRejectsEntryOutsideRoot() {
        let root = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        let entry = URL(fileURLWithPath: "/elsewhere/Notes/Meeting.md")
        XCTAssertNil(ICloudVaultMigrator.relativeFilePath(of: entry, under: root))
    }

    func testRelativeFilePathRejectsRootItself() {
        let root = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        XCTAssertNil(ICloudVaultMigrator.relativeFilePath(of: root, under: root))
    }

    func testRelativeFilePathDoesNotMatchSiblingPrefix() {
        // "/vault/Notes2" must not be considered under "/vault/Notes".
        let root = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        let entry = URL(fileURLWithPath: "/vault/Notes2/Meeting.md")
        XCTAssertNil(ICloudVaultMigrator.relativeFilePath(of: entry, under: root))
    }

    // MARK: - destinationURL

    func testDestinationURLPreservesNestedStructure() {
        let dest = URL(fileURLWithPath: "/icloud/Documents/Scribe/Notes", isDirectory: true)
        let url = ICloudVaultMigrator.destinationURL(
            forRelativePath: "Daily/2026-06-15.md",
            destinationRoot: dest
        )
        XCTAssertTrue(url.path.hasSuffix("/icloud/Documents/Scribe/Notes/Daily/2026-06-15.md"),
                      "got \(url.path)")
    }

    func testDestinationURLTopLevel() {
        let dest = URL(fileURLWithPath: "/icloud/Notes", isDirectory: true)
        let url = ICloudVaultMigrator.destinationURL(
            forRelativePath: "Meeting.md",
            destinationRoot: dest
        )
        XCTAssertEqual(url.lastPathComponent, "Meeting.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Notes")
    }

    func testRelativeThenDestinationRoundTrips() {
        // relativeFilePath ∘ destinationURL should reproduce the original
        // entry under a matching root.
        let root = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        let entry = URL(fileURLWithPath: "/vault/Notes/a/b/c.md")
        let rel = ICloudVaultMigrator.relativeFilePath(of: entry, under: root)
        XCTAssertEqual(rel, "a/b/c.md")
        let mapped = ICloudVaultMigrator.destinationURL(forRelativePath: rel!, destinationRoot: root)
        XCTAssertEqual(mapped.standardizedFileURL, entry.standardizedFileURL)
    }

    // MARK: - entriesToCopy

    func testEntriesToCopyExcludesExistingDestination() {
        let result = ICloudVaultMigrator.entriesToCopy(
            sourceRelativePaths: ["a.md", "b.md", "Daily/x.md"],
            existingDestinationRelativePaths: ["b.md"]
        )
        XCTAssertEqual(result, ["Daily/x.md", "a.md"])
    }

    func testEntriesToCopyEverythingWhenDestinationEmpty() {
        let result = ICloudVaultMigrator.entriesToCopy(
            sourceRelativePaths: ["b.md", "a.md"],
            existingDestinationRelativePaths: []
        )
        // Sorted for determinism.
        XCTAssertEqual(result, ["a.md", "b.md"])
    }

    func testEntriesToCopyNothingWhenAllPresent() {
        let result = ICloudVaultMigrator.entriesToCopy(
            sourceRelativePaths: ["a.md", "b.md"],
            existingDestinationRelativePaths: ["a.md", "b.md", "extra.md"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEntriesToCopyDeduplicatesSource() {
        let result = ICloudVaultMigrator.entriesToCopy(
            sourceRelativePaths: ["a.md", "a.md", "b.md"],
            existingDestinationRelativePaths: []
        )
        XCTAssertEqual(result, ["a.md", "b.md"])
    }
}
