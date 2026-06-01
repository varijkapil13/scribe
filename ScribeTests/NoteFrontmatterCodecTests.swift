// ScribeTests/NoteFrontmatterCodecTests.swift
import XCTest
@testable import Scribe

/// Phase 0 safety gate: the frontmatter codec must preserve keys it doesn't
/// model with a typed field, so external-tool metadata and Scribe's own
/// additive keys (`cover:`/`icon:`/`font:`) survive a round-trip instead of
/// being silently dropped on the next save.
final class NoteFrontmatterCodecTests: XCTestCase {

    private func sampleFrontmatter(extra: [FrontmatterEntry] = []) -> NoteFrontmatter {
        NoteFrontmatter(
            title: "My Note",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            notebookId: "nb-1",
            tags: ["foo", "bar"],
            isDailyNote: false,
            dailyDate: nil,
            extra: extra
        )
    }

    func testUnknownKeysSurviveDecodeThenReEncode() {
        let file = """
        ---
        id: 9e3b8a1f-1f6e-4f3c-9d4a-2b1c6c7e1234
        title: My Note
        created: 2023-11-14T22:13:20.000Z
        updated: 2023-11-14T22:21:40.000Z
        notebookId: nb-1
        tags: [foo, bar]
        isDailyNote: false
        dailyDate:
        cover: attachments/hero.png
        icon: 📓
        aliases: [Alpha, Beta]
        ---

        Body text here.
        """

        let decoded = NoteFrontmatterCodec.decodeFile(
            contents: file, fallbackTitle: "fallback", fallbackId: "fallback-id"
        )

        // Unknown keys captured, in file order, verbatim.
        XCTAssertEqual(decoded.frontmatter.extra, [
            FrontmatterEntry(key: "cover", value: "attachments/hero.png"),
            FrontmatterEntry(key: "icon", value: "📓"),
            FrontmatterEntry(key: "aliases", value: "[Alpha, Beta]"),
        ])
        // Typed keys still parsed.
        XCTAssertEqual(decoded.frontmatter.title, "My Note")
        XCTAssertEqual(decoded.frontmatter.notebookId, "nb-1")
        XCTAssertEqual(decoded.frontmatter.tags, ["foo", "bar"])
        XCTAssertEqual(decoded.body, "Body text here.")

        // Re-encode and decode again — extras must still be present + equal.
        let reEncoded = NoteFrontmatterCodec.encodeFile(
            id: decoded.id, frontmatter: decoded.frontmatter, body: decoded.body
        )
        let reDecoded = NoteFrontmatterCodec.decodeFile(
            contents: reEncoded, fallbackTitle: "fallback", fallbackId: "fallback-id"
        )
        XCTAssertEqual(reDecoded.frontmatter.extra, decoded.frontmatter.extra)
        XCTAssertEqual(reDecoded.id, decoded.id)
    }

    func testEncodeEmitsExtrasAfterTypedKeysBeforeClosingDelimiter() {
        let fm = sampleFrontmatter(extra: [
            FrontmatterEntry(key: "cover", value: "attachments/hero.png"),
            FrontmatterEntry(key: "font", value: "serif"),
        ])
        let encoded = NoteFrontmatterCodec.encode(id: "the-id", frontmatter: fm)
        let lines = encoded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let dailyIdx = lines.firstIndex(where: { $0.hasPrefix("dailyDate") }),
              let coverIdx = lines.firstIndex(of: "cover: attachments/hero.png"),
              let fontIdx = lines.firstIndex(of: "font: serif"),
              let closingIdx = lines.indices.last(where: { lines[$0] == "---" }) else {
            return XCTFail("expected extras between dailyDate and the closing delimiter")
        }
        XCTAssertGreaterThan(coverIdx, dailyIdx, "extras come after the typed block")
        XCTAssertLessThan(fontIdx, closingIdx, "extras come before the closing delimiter")
    }

    func testSetExtraRoundTripsThroughTheCodec() {
        var fm = sampleFrontmatter()
        fm.setExtra("font", "serif")
        XCTAssertEqual(fm.extraValue(forKey: "font"), "serif")

        let encoded = NoteFrontmatterCodec.encodeFile(id: "id-1", frontmatter: fm, body: "Hi")
        let decoded = NoteFrontmatterCodec.decodeFile(
            contents: encoded, fallbackTitle: "x", fallbackId: "y"
        )
        XCTAssertEqual(decoded.frontmatter.extraValue(forKey: "font"), "serif")

        // Clearing removes it on the next encode.
        var cleared = decoded.frontmatter
        cleared.setExtra("font", nil)
        let reEncoded = NoteFrontmatterCodec.encodeFile(id: "id-1", frontmatter: cleared, body: "Hi")
        XCTAssertFalse(reEncoded.contains("font:"))
    }

    func testTypedKeysAreNeverCapturedAsExtras() {
        // A file whose only keys are the typed ones must produce empty extras.
        let file = """
        ---
        id: abc
        title: T
        created: 2023-11-14T22:13:20.000Z
        updated: 2023-11-14T22:13:20.000Z
        notebookId:
        tags: []
        isDailyNote: false
        dailyDate:
        ---
        Body
        """
        let decoded = NoteFrontmatterCodec.decodeFile(
            contents: file, fallbackTitle: "f", fallbackId: "f"
        )
        XCTAssertTrue(decoded.frontmatter.extra.isEmpty)
    }
}
