import XCTest
@testable import Scribe

final class FoldRegistryTests: XCTestCase {

    func testEmptyRegistryIsIdentity() {
        let r: [FoldEntry] = []
        XCTAssertEqual(FoldRegistry.sourceLocation(forDisplay: 5, registry: r), 5)
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 5, registry: r), 5)
    }

    func testDisplayToSourceAfterSingleFold() {
        // One fold: display index 6 is the attachment, originally 23 chars long in source.
        let r = [FoldEntry(id: UUID(), displayLocation: 6, sourceLocation: 6, sourceLength: 23)]
        // Display position 0 → source 0 (before fold).
        XCTAssertEqual(FoldRegistry.sourceLocation(forDisplay: 0, registry: r), 0)
        // Display position 6 → source 6 (the attachment glyph itself maps to fold start).
        XCTAssertEqual(FoldRegistry.sourceLocation(forDisplay: 6, registry: r), 6)
        // Display position 7 → source 6 + 23 = 29 (just past the fold).
        XCTAssertEqual(FoldRegistry.sourceLocation(forDisplay: 7, registry: r), 29)
        // Display position 12 → source 29 + 5 = 34.
        XCTAssertEqual(FoldRegistry.sourceLocation(forDisplay: 12, registry: r), 34)
    }

    func testSourceToDisplayAfterSingleFold() {
        let r = [FoldEntry(id: UUID(), displayLocation: 6, sourceLocation: 6, sourceLength: 23)]
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 0, registry: r), 0)
        // Source 6 (start of fence) → display 6 (the attachment).
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 6, registry: r), 6)
        // Source 15 (inside fence) → display 6 (clamped to attachment; cursor here causes expand).
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 15, registry: r), 6)
        // Source 29 (just past fence) → display 7.
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 29, registry: r), 7)
        // Source 34 → display 12.
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 34, registry: r), 12)
    }

    func testTwoFoldsCompoundCorrectly() {
        // First fold at source [10, 30) length 20. Second at source [50, 80) length 30.
        // After folding, display: source[0..10] + ATT + source[30..50] + ATT + source[80..]
        // displayLocation(first)  = 10
        // displayLocation(second) = 10 + 1 + (50-30) = 31
        let r = [
            FoldEntry(id: UUID(), displayLocation: 10, sourceLocation: 10, sourceLength: 20),
            FoldEntry(id: UUID(), displayLocation: 31, sourceLocation: 50, sourceLength: 30),
        ]
        // Source 35 (between folds) → display 10 + 1 + (35-30) = 16
        XCTAssertEqual(FoldRegistry.displayLocation(forSource: 35, registry: r), 16)
        // Display 20 (between attachments) → source 10 + (20-10-1) + 20 = 39
        // Walk: folds with displayLocation < 20: first (yes, contributes 20-1 = 19). second no.
        // sourceLoc = 20 + 19 = 39 ✓
        XCTAssertEqual(FoldRegistry.sourceLocation(forDisplay: 20, registry: r), 39)
    }
}
