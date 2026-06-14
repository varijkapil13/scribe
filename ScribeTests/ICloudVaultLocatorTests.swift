import XCTest
@testable import Scribe

final class ICloudVaultLocatorTests: XCTestCase {

    func testNotesURLMirrorsLocalVaultLayout() {
        let container = URL(fileURLWithPath: "/Containers/iCloud~com~varij~scribe", isDirectory: true)
        let url = ICloudVaultLocator.notesURL(forContainer: container)
        XCTAssertTrue(url.path.hasSuffix("/Documents/Scribe/Notes"),
                      "iCloud vault must live at <container>/Documents/Scribe/Notes; got \(url.path)")
        XCTAssertTrue(url.hasDirectoryPath)
    }
}
