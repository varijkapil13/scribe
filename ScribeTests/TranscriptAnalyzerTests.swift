import XCTest
@testable import Scribe

/// Real-input tests for ``TranscriptAnalyzer``. These hit Apple's
/// `NaturalLanguage` framework directly (no mocks) so they catch regressions
/// in the wiring against the real on-device taggers.
final class TranscriptAnalyzerTests: XCTestCase {

    private func segments(_ pairs: [(speaker: String, text: String)]) -> [Segment] {
        pairs.enumerated().map { offset, pair in
            Segment(
                sessionId: "test",
                startMs: offset * 5_000,
                endMs: (offset + 1) * 5_000,
                speaker: pair.speaker,
                text: pair.text
            )
        }
    }

    // MARK: - Entity extraction

    func testExtractEntitiesFindsPersonAndPlace() {
        let input = segments([
            ("you", "Alice and Bob met in Paris last week."),
            ("you", "They talked about the upcoming trip to Tokyo."),
        ])

        let entities = TranscriptAnalyzer.extractEntities(from: input)
        let personNames = Set(entities.filter { $0.type == .person }.map { $0.text.lowercased() })
        let places = Set(entities.filter { $0.type == .place }.map { $0.text.lowercased() })

        XCTAssertTrue(personNames.contains("alice"), "expected Alice in \(personNames)")
        XCTAssertTrue(personNames.contains("bob"), "expected Bob in \(personNames)")
        XCTAssertTrue(places.contains("paris") || places.contains("tokyo"), "expected a place in \(places)")
    }

    func testExtractEntitiesDeduplicatesCaseInsensitively() {
        let input = segments([
            ("you", "Alice spoke with Alice again. ALICE smiled."),
        ])
        let people = TranscriptAnalyzer.extractEntities(from: input)
            .filter { $0.type == .person }
        // Three "alice" mentions collapse to a single dedup'd entry.
        XCTAssertEqual(people.filter { $0.text.lowercased() == "alice" }.count, 1)
    }

    func testExtractEntitiesEmptyInputReturnsEmpty() {
        XCTAssertEqual(TranscriptAnalyzer.extractEntities(from: []).count, 0)
    }

    // MARK: - Language detection

    func testDetectLanguageEnglish() {
        let input = segments([
            ("you", "This is an entirely English sentence about meetings, planning, and outcomes."),
            ("you", "Today we will discuss the quarterly review and share ideas with the team."),
        ])
        let detection = TranscriptAnalyzer.detectLanguage(from: input)
        XCTAssertEqual(detection.primaryLanguage, "en")
        XCTAssertGreaterThan(detection.confidence, 0.5)
    }

    func testDetectLanguageReturnsUndeterminedForEmpty() {
        let detection = TranscriptAnalyzer.detectLanguage(from: [])
        // NLLanguageRecognizer returns .undetermined → "und" code in our wrapper.
        XCTAssertEqual(detection.primaryLanguage, "und")
    }

    // MARK: - Sentiment

    func testSentimentOnPositiveText() {
        let input = segments([
            ("you", "I love this idea. It's wonderful, exciting, and absolutely brilliant. Everyone seems happy."),
        ])
        let result = TranscriptAnalyzer.analyzeSentiment(of: input)
        XCTAssertGreaterThanOrEqual(result.overallScore, 0)
    }

    func testSentimentPerSpeakerKeysMatchInput() {
        let input = segments([
            ("you", "I think the timeline is great and the team is energized."),
            ("remote", "I disagree strongly. This is a terrible plan."),
        ])
        let result = TranscriptAnalyzer.analyzeSentiment(of: input)
        XCTAssertEqual(Set(result.perSpeaker.keys), Set(["you", "remote"]))
    }

    // MARK: - Topic extraction

    func testExtractTopicsReturnsHighFrequencyNouns() {
        let input = segments([
            ("you", "The roadmap is the priority. The roadmap drives planning. Roadmap reviews matter."),
            ("you", "Budget concerns. Budget meetings. Budget approvals."),
        ])
        let topics = TranscriptAnalyzer.extractTopics(from: input, topN: 5)
        XCTAssertTrue(topics.topics.contains("roadmap"), "topics: \(topics.topics)")
        XCTAssertTrue(topics.topics.contains("budget"), "topics: \(topics.topics)")
    }

    func testExtractTopicsRespectsTopNLimit() {
        let input = segments([
            ("you", "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"),
        ])
        let topics = TranscriptAnalyzer.extractTopics(from: input, topN: 3)
        XCTAssertLessThanOrEqual(topics.topics.count, 3)
    }

    // MARK: - Key phrases

    func testExtractKeyPhrasesIdentifiesMultiWordSequences() {
        let input = segments([
            ("you", "We launched the new product roadmap and shared the new product roadmap with leadership."),
        ])
        let phrases = TranscriptAnalyzer.extractKeyPhrases(from: input)
        XCTAssertTrue(phrases.contains { $0.contains("roadmap") }, "phrases: \(phrases)")
    }

    // MARK: - Combined analysis

    func testAnalyzeTranscriptPopulatesAllFields() {
        let input = segments([
            ("you", "Alice from ACME proposed a new pricing model for the enterprise tier."),
            ("remote", "I think it's a great idea — the new pricing model will help us close deals."),
        ])
        let analysis = TranscriptAnalyzer.analyzeTranscript(segments: input)

        XCTAssertFalse(analysis.entities.isEmpty)
        XCTAssertEqual(analysis.language.primaryLanguage, "en")
        XCTAssertNotNil(analysis.sentiment.label)
        XCTAssertFalse(analysis.topics.topics.isEmpty)
    }
}
