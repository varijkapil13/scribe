// ScribeTests/NotePropertyTests.swift
import XCTest
@testable import Scribe

/// Round-trip + inference tests for the typed note-property model that backs
/// the Bases feature. Properties parse from / serialize to the frontmatter
/// `extra` map, so the codec must re-read whatever the model writes.
final class NotePropertyTests: XCTestCase {

    private func frontmatter(extra: [FrontmatterEntry]) -> NoteFrontmatter {
        NoteFrontmatter(
            title: "T",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            extra: extra
        )
    }

    // MARK: - Type inference

    func testInferenceFromRawValues() {
        XCTAssertEqual(PropertyValue.parse("true"), .checkbox(true))
        XCTAssertEqual(PropertyValue.parse("false"), .checkbox(false))
        XCTAssertEqual(PropertyValue.parse("42"), .number(42))
        XCTAssertEqual(PropertyValue.parse("3.5"), .number(3.5))
        XCTAssertEqual(PropertyValue.parse("[a, b, c]"), .list(["a", "b", "c"]))
        XCTAssertEqual(PropertyValue.parse("hello world"), .text("hello world"))

        if case .date(let d) = PropertyValue.parse("2026-06-15") {
            XCTAssertEqual(PropertyCodec.dateFormatter.string(from: d), "2026-06-15")
        } else {
            XCTFail("Expected date inference")
        }
    }

    func testExplicitTypeCoercion() {
        // A bare scalar pinned to .list becomes a single-element list.
        XCTAssertEqual(PropertyValue.parse("solo", as: .list), .list(["solo"]))
        // A number string pinned to .text stays text.
        XCTAssertEqual(PropertyValue.parse("42", as: .text), .text("42"))
        // "yes" is not a checkbox keyword → coerces to unchecked.
        XCTAssertEqual(PropertyValue.parse("yes", as: .checkbox), .checkbox(false))
        XCTAssertEqual(PropertyValue.parse("Done", as: .select), .select("Done"))
    }

    // MARK: - Encoding

    func testEncodingConventions() {
        XCTAssertEqual(PropertyValue.number(3).encoded, "3")
        XCTAssertEqual(PropertyValue.number(3.5).encoded, "3.5")
        XCTAssertEqual(PropertyValue.checkbox(true).encoded, "true")
        XCTAssertEqual(PropertyValue.list(["a", "b"]).encoded, "[a, b]")
        XCTAssertEqual(PropertyValue.text("plain").encoded, "plain")
        // Scalars with structural chars get quoted so the codec re-reads them.
        XCTAssertEqual(PropertyValue.text("a, b: c").encoded, "\"a, b: c\"")
    }

    // MARK: - Round-trip through frontmatter

    func testRoundTripThroughFrontmatter() {
        let original: [NoteProperty] = [
            NoteProperty(key: "status", value: .select("In Progress")),
            NoteProperty(key: "priority", value: .number(2)),
            NoteProperty(key: "starred", value: .checkbox(true)),
            NoteProperty(key: "topics", value: .list(["swift", "macos"])),
            NoteProperty(key: "summary", value: .text("hi")),
        ]

        var fm = frontmatter(extra: [])
        fm.applyProperties(original)

        // Re-read with select/number type hints so the inferred shapes match.
        let hints: [String: PropertyType] = ["status": .select, "priority": .number]
        let parsed = fm.properties(typeHints: hints)

        XCTAssertEqual(parsed.count, original.count)
        XCTAssertEqual(parsed.first { $0.key == "status" }?.value, .select("In Progress"))
        XCTAssertEqual(parsed.first { $0.key == "priority" }?.value, .number(2))
        XCTAssertEqual(parsed.first { $0.key == "starred" }?.value, .checkbox(true))
        XCTAssertEqual(parsed.first { $0.key == "topics" }?.value, .list(["swift", "macos"]))
        XCTAssertEqual(parsed.first { $0.key == "summary" }?.value, .text("hi"))
    }

    func testFullCodecRoundTrip() {
        // Properties written into extra must survive an encode → decode cycle
        // through the real NoteFrontmatterCodec.
        var fm = frontmatter(extra: [])
        fm.applyProperties([
            NoteProperty(key: "status", value: .select("Done")),
            NoteProperty(key: "topics", value: .list(["a", "b"])),
        ])

        let encoded = NoteFrontmatterCodec.encode(id: "id-1", frontmatter: fm)
        let decoded = NoteFrontmatterCodec.decodeFile(
            contents: encoded + "\nbody",
            fallbackTitle: "fallback",
            fallbackId: "fallback-id"
        )

        XCTAssertEqual(decoded.frontmatter.extraValue(forKey: "status"), "Done")
        XCTAssertEqual(decoded.frontmatter.extraValue(forKey: "topics"), "[a, b]")
        let props = decoded.frontmatter.properties(typeHints: ["status": .select])
        XCTAssertEqual(props.first { $0.key == "status" }?.value, .select("Done"))
        XCTAssertEqual(props.first { $0.key == "topics" }?.value, .list(["a", "b"]))
    }

    // MARK: - Reserved keys

    func testReservedKeysNotSurfacedOrWritten() {
        var fm = frontmatter(extra: [FrontmatterEntry(key: "font", value: "Menlo")])
        // Properties view skips reserved keys (font/cover/icon).
        XCTAssertTrue(fm.properties().isEmpty)
        // Writing a reserved key via the typed API is ignored.
        fm.setProperty("title", .text("Hacked"))
        XCTAssertNil(fm.extraValue(forKey: "title"))
    }

    func testApplyPropertiesPreservesReservedExtras() {
        var fm = frontmatter(extra: [FrontmatterEntry(key: "font", value: "Menlo")])
        fm.applyProperties([NoteProperty(key: "status", value: .select("Done"))])
        // Reserved font extra survives a bulk apply.
        XCTAssertEqual(fm.extraValue(forKey: "font"), "Menlo")
        XCTAssertEqual(fm.extraValue(forKey: "status"), "Done")
    }

    func testEmptyValueRemovesKey() {
        var fm = frontmatter(extra: [FrontmatterEntry(key: "note", value: "x")])
        fm.setProperty("note", .text(""))
        XCTAssertNil(fm.extraValue(forKey: "note"))
    }
}
