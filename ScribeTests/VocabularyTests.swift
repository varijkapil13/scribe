import XCTest
@testable import Scribe

/// Custom vocabulary: file format, the whole-word corrector, and the store.
@MainActor
final class VocabularyTests: XCTestCase {

    private func corrector(_ pairs: [(String, String)]) -> VocabularyCorrector {
        VocabularyCorrector(corrections: pairs.map { VocabularyCorrection(heardAs: $0.0, replacement: $0.1) })
    }

    // MARK: - Corrector

    func testReplacesWholeWordCaseInsensitively() {
        let c = corrector([("scribe", "Scribe")])
        XCTAssertEqual(c.apply(to: "I love scribe and SCRIBE"), "I love Scribe and Scribe")
    }

    func testDoesNotReplaceInsideOtherWords() {
        let c = corrector([("ai", "AI"), ("cat", "Kat")])
        XCTAssertEqual(c.apply(to: "she said the cats concatenate"), "she said the cats concatenate")
        XCTAssertEqual(c.apply(to: "ai, cat."), "AI, Kat.")
    }

    func testHandlesAdjacentPunctuation() {
        let c = corrector([("priya", "Priya")])
        XCTAssertEqual(c.apply(to: "Thanks, priya."), "Thanks, Priya.")
        XCTAssertEqual(c.apply(to: "(priya)"), "(Priya)")
        XCTAssertEqual(c.apply(to: "priya's deck"), "Priya's deck")
        XCTAssertEqual(c.apply(to: "\"priya\"?"), "\"Priya\"?")
        XCTAssertEqual(c.apply(to: "priya"), "Priya")
    }

    func testMultiWordPhrasesMatchAcrossWhitespace() {
        let c = corrector([("cube control", "kubectl")])
        XCTAssertEqual(c.apply(to: "run cube control get pods"), "run kubectl get pods")
        XCTAssertEqual(c.apply(to: "run Cube   Control, then"), "run kubectl, then")
        XCTAssertEqual(c.apply(to: "cube controller"), "cube controller")
    }

    func testLongestPhraseWinsAndSinglePass() {
        let c = corrector([("cube", "Cube"), ("cube control", "kubectl"), ("kubectl", "WRONG")])
        // "cube control" beats "cube"; the inserted "kubectl" is not re-matched.
        XCTAssertEqual(c.apply(to: "cube control and cube"), "kubectl and Cube")
    }

    func testReplacementIsInsertedLiterally() {
        let c = corrector([("dollar", "$1 \\0")])
        XCTAssertEqual(c.apply(to: "one dollar"), "one $1 \\0")
    }

    func testRegexMetacharactersInHeardAsAreEscaped() {
        let c = corrector([("c++", "C++"), ("a.b", "AB")])
        XCTAssertEqual(c.apply(to: "I write c++ daily"), "I write C++ daily")
        XCTAssertEqual(c.apply(to: "axb a.b"), "axb AB")
    }

    func testEmptyCorrectorIsIdentity() {
        let c = VocabularyCorrector(corrections: [])
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.apply(to: "unchanged text"), "unchanged text")
    }

    func testFirstRuleWinsForDuplicateHeardAs() {
        let c = corrector([("teh", "the"), ("TEH", "tea")])
        XCTAssertEqual(c.apply(to: "teh end"), "the end")
    }

    // MARK: - File format

    func testParseTermsCorrectionsAndComments() {
        let text = """
        # Scribe vocabulary

        <!-- comment -->
        - Kubernetes
        - cube control -> kubectl
        * pre a → Priya
        Plain line
        - Kubernetes
        -
        """
        let entries = VocabularyFile.parse(text)
        XCTAssertEqual(entries, [
            VocabularyEntry(term: "Kubernetes"),
            VocabularyEntry(term: "kubectl", heardAs: "cube control"),
            VocabularyEntry(term: "Priya", heardAs: "pre a"),
            VocabularyEntry(term: "Plain line"),
        ])
    }

    func testSerializeRoundTrips() {
        let entries = [
            VocabularyEntry(term: "Kubernetes"),
            VocabularyEntry(term: "kubectl", heardAs: "cube control"),
        ]
        let text = VocabularyFile.serialize(entries)
        XCTAssertTrue(text.hasPrefix(VocabularyFile.header))
        XCTAssertTrue(text.contains("- cube control -> kubectl"))
        XCTAssertEqual(VocabularyFile.parse(text), entries)
    }

    func testContextualStringsAreUniqueTerms() {
        let entries = [
            VocabularyEntry(term: "kubectl", heardAs: "cube control"),
            VocabularyEntry(term: "kubectl", heardAs: "cube cuddle"),
            VocabularyEntry(term: "Priya"),
        ]
        XCTAssertEqual(VocabularyFile.contextualStrings(for: entries), ["kubectl", "Priya"])
        XCTAssertEqual(VocabularyFile.corrections(for: entries).count, 2)
    }

    func testEntryWithIdenticalHeardAsHasNoCorrection() {
        XCTAssertNil(VocabularyEntry(term: "Scribe", heardAs: "Scribe").correction)
        XCTAssertNotNil(VocabularyEntry(term: "Scribe", heardAs: "scribe").correction)
        XCTAssertNil(VocabularyEntry(term: "Scribe", heardAs: "  ").heardAs)
    }

    // MARK: - Store

    func testStorePersistsToFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vocabulary.md")

        let store = VocabularyStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.add(term: "kubectl", heardAs: "cube control"))
        XCTAssertFalse(store.add(term: "kubectl", heardAs: "Cube  Control"), "duplicate")
        XCTAssertTrue(store.add(term: "Priya"))
        XCTAssertFalse(store.add(term: "   "))

        let reopened = VocabularyStore(fileURL: url)
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.contextualStrings, ["kubectl", "Priya"])
        XCTAssertEqual(reopened.makeCorrector().apply(to: "cube control"), "kubectl")

        reopened.remove(reopened.entries[0])
        XCTAssertEqual(VocabularyStore(fileURL: url).entries, [VocabularyEntry(term: "Priya")])
    }
}
