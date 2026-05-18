// ScribeTests/NotesDirectoryPreferenceTests.swift
import Darwin
import XCTest
@testable import Scribe

private func realpathString(_ path: String) -> String {
    path.withCString { c in
        guard let p = realpath(c, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }
}

/// Slice 8 contract: `NotesDirectory.defaultLocation()` honours the user
/// preference at `NotesDirectory.userPreferenceKey` when set, and falls
/// back to `~/Documents/Scribe/Notes/` otherwise.
final class NotesDirectoryPreferenceTests: XCTestCase {

    private let key = NotesDirectory.userPreferenceKey
    private var savedValue: String?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testDefaultsToDocumentsScribeNotesWhenUnset() throws {
        let dir = try NotesDirectory.defaultLocation()
        XCTAssertTrue(dir.root.path.hasSuffix("/Scribe/Notes"),
                      "Expected default vault under Documents/Scribe/Notes, got \(dir.root.path)")
    }

    func testEmptyStringFallsBackToDefault() throws {
        UserDefaults.standard.set("", forKey: key)
        let dir = try NotesDirectory.defaultLocation()
        XCTAssertTrue(dir.root.path.hasSuffix("/Scribe/Notes"))
    }

    func testUserPreferenceOverridesDefault() throws {
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: custom) }
        UserDefaults.standard.set(custom.path, forKey: key)

        let dir = try NotesDirectory.defaultLocation()
        // realpath collapses /var/folders → /private/var/folders; the
        // resolver only works on paths that exist, which is why we
        // ensure the override directory has been materialised first
        // (defaultLocation creates it).
        XCTAssertEqual(dir.root.path, realpathString(custom.path))
    }

    func testCreatesOverrideDirectoryIfMissing() throws {
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: custom.deletingLastPathComponent()) }
        UserDefaults.standard.set(custom.path, forKey: key)

        _ = try NotesDirectory.defaultLocation()
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.path))
    }

    func testBuiltInDefaultMatchesUnsetBehaviour() throws {
        let unset = try NotesDirectory.defaultLocation()
        let builtIn = NotesDirectory.builtInDefault()
        XCTAssertEqual(unset.root.path, realpathString(builtIn.path))
    }
}
