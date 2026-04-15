import Foundation
import NaturalLanguage

// MARK: - Data Models

/// A named entity extracted from transcript text.
struct ExtractedEntity: Identifiable, Equatable, Hashable {
    let id: UUID
    let text: String
    let type: EntityType
    let range: Range<String.Index>?
    let segmentId: Int64?

    /// The kind of named entity recognized by the NaturalLanguage framework.
    enum EntityType: String, CaseIterable, Identifiable {
        case person = "Person"
        case organization = "Organization"
        case place = "Place"
        case date = "Date/Time"

        var id: String { rawValue }

        /// SF Symbol name for display.
        var systemImage: String {
            switch self {
            case .person:       return "person.fill"
            case .organization: return "building.2.fill"
            case .place:        return "mappin.circle.fill"
            case .date:         return "calendar"
            }
        }
    }

    // Equatable/Hashable ignore range (it's not Hashable).
    static func == (lhs: ExtractedEntity, rhs: ExtractedEntity) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.type == rhs.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
        hasher.combine(type)
    }
}

/// Language detection result for a transcript.
struct LanguageDetection: Equatable {
    let primaryLanguage: String
    let primaryLanguageName: String
    let confidence: Double
    let allLanguages: [(language: String, name: String, confidence: Double)]

    static func == (lhs: LanguageDetection, rhs: LanguageDetection) -> Bool {
        lhs.primaryLanguage == rhs.primaryLanguage && lhs.confidence == rhs.confidence
    }
}

/// Sentiment analysis result.
struct SentimentResult: Equatable {
    let overallScore: Double
    let label: String
    let perSpeaker: [String: Double]
}

/// Key topics extracted from the transcript.
struct TopicExtraction: Equatable {
    let topics: [String]
    let wordFrequency: [(word: String, count: Int)]

    static func == (lhs: TopicExtraction, rhs: TopicExtraction) -> Bool {
        lhs.topics == rhs.topics
    }
}

/// Combined analysis results for a transcript.
struct TranscriptAnalysis: Equatable {
    let entities: [ExtractedEntity]
    let language: LanguageDetection
    let sentiment: SentimentResult
    let topics: TopicExtraction
    let keyPhrases: [String]
}

// MARK: - TranscriptAnalyzer

/// Analyzes transcript text using Apple's NaturalLanguage framework.
/// All processing is on-device with no network requests.
struct TranscriptAnalyzer {

    // MARK: - Full Analysis

    /// Runs all available analyses on the given segments and returns combined results.
    static func analyzeTranscript(segments: [Segment]) -> TranscriptAnalysis {
        TranscriptAnalysis(
            entities: extractEntities(from: segments),
            language: detectLanguage(from: segments),
            sentiment: analyzeSentiment(of: segments),
            topics: extractTopics(from: segments),
            keyPhrases: extractKeyPhrases(from: segments)
        )
    }

    // MARK: - Entity Extraction

    /// Extracts named entities (people, organizations, places) from segments.
    ///
    /// Uses `NLTagger` with the `.nameType` scheme. Entities are deduplicated
    /// by case-insensitive text matching and sorted by frequency.
    static func extractEntities(from segments: [Segment]) -> [ExtractedEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        var entityCounts: [String: (text: String, type: ExtractedEntity.EntityType, segmentId: Int64?)] = [:]

        for segment in segments {
            tagger.string = segment.text
            let range = segment.text.startIndex..<segment.text.endIndex

            tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, tokenRange in
                guard let tag else { return true }

                let entityType: ExtractedEntity.EntityType?
                switch tag {
                case .personalName:     entityType = .person
                case .organizationName: entityType = .organization
                case .placeName:        entityType = .place
                default:                entityType = nil
                }

                if let entityType {
                    let text = String(segment.text[tokenRange])
                    let key = text.lowercased()
                    if entityCounts[key] == nil {
                        entityCounts[key] = (text: text, type: entityType, segmentId: segment.id)
                    }
                }
                return true
            }
        }

        return entityCounts.values
            .map { value in
                ExtractedEntity(
                    id: UUID(),
                    text: value.text,
                    type: value.type,
                    range: nil,
                    segmentId: value.segmentId
                )
            }
            .sorted { $0.text.lowercased() < $1.text.lowercased() }
    }

    // MARK: - Language Detection

    /// Detects the primary language and language distribution of the transcript.
    static func detectLanguage(from segments: [Segment]) -> LanguageDetection {
        let recognizer = NLLanguageRecognizer()
        let combined = segments.prefix(50).map(\.text).joined(separator: " ")
        let sample = String(combined.prefix(4000))

        recognizer.processString(sample)

        let dominant = recognizer.dominantLanguage
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let primaryCode = dominant?.rawValue ?? "und"
        let primaryName = languageDisplayName(for: primaryCode)
        let primaryConfidence = hypotheses[dominant ?? .undetermined] ?? 0

        let allLanguages = hypotheses
            .sorted { $0.value > $1.value }
            .map { (language: $0.key.rawValue, name: languageDisplayName(for: $0.key.rawValue), confidence: $0.value) }

        return LanguageDetection(
            primaryLanguage: primaryCode,
            primaryLanguageName: primaryName,
            confidence: primaryConfidence,
            allLanguages: allLanguages
        )
    }

    // MARK: - Sentiment Analysis

    /// Computes overall and per-speaker sentiment scores.
    ///
    /// Scores range from -1.0 (very negative) to 1.0 (very positive).
    static func analyzeSentiment(of segments: [Segment]) -> SentimentResult {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var totalScore = 0.0
        var count = 0
        var speakerScores: [String: (total: Double, count: Int)] = [:]

        for segment in segments {
            tagger.string = segment.text
            let range = segment.text.startIndex..<segment.text.endIndex

            tagger.enumerateTags(in: range, unit: .paragraph, scheme: .sentimentScore) { tag, _ in
                if let tag, let score = Double(tag.rawValue) {
                    totalScore += score
                    count += 1

                    let current = speakerScores[segment.speaker, default: (total: 0, count: 0)]
                    speakerScores[segment.speaker] = (total: current.total + score, count: current.count + 1)
                }
                return true
            }
        }

        let overall = count > 0 ? totalScore / Double(count) : 0
        let label: String
        if overall > 0.1 {
            label = "Positive"
        } else if overall < -0.1 {
            label = "Negative"
        } else {
            label = "Neutral"
        }

        let perSpeaker = speakerScores.mapValues { $0.count > 0 ? $0.total / Double($0.count) : 0 }

        return SentimentResult(overallScore: overall, label: label, perSpeaker: perSpeaker)
    }

    // MARK: - Topic Extraction

    /// Extracts key topics by analyzing noun frequency after filtering stop words.
    static func extractTopics(from segments: [Segment], topN: Int = 10) -> TopicExtraction {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        var wordCounts: [String: Int] = [:]

        for segment in segments {
            tagger.string = segment.text
            let range = segment.text.startIndex..<segment.text.endIndex

            tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
                guard let tag, tag == .noun || tag == .verb else { return true }

                let word = String(segment.text[tokenRange]).lowercased()
                guard word.count >= 3, !stopWords.contains(word) else { return true }

                wordCounts[word, default: 0] += 1
                return true
            }
        }

        let sorted = wordCounts.sorted { $0.value > $1.value }
        let topics = sorted.prefix(topN).map(\.key)
        let frequency = sorted.prefix(topN * 2).map { (word: $0.key, count: $0.value) }

        return TopicExtraction(topics: topics, wordFrequency: frequency)
    }

    // MARK: - Key Phrase Extraction

    /// Extracts multi-word key phrases from the transcript.
    ///
    /// Identifies consecutive noun sequences that form meaningful phrases.
    static func extractKeyPhrases(from segments: [Segment], maxPhrases: Int = 15) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        var phraseCounts: [String: Int] = [:]

        for segment in segments {
            tagger.string = segment.text
            let range = segment.text.startIndex..<segment.text.endIndex

            var currentPhrase: [String] = []

            tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
                let word = String(segment.text[tokenRange])

                if let tag, (tag == .noun || tag == .adjective) {
                    currentPhrase.append(word)
                } else {
                    if currentPhrase.count >= 2 {
                        let phrase = currentPhrase.joined(separator: " ").lowercased()
                        if !stopWords.contains(phrase) {
                            phraseCounts[phrase, default: 0] += 1
                        }
                    }
                    currentPhrase = []
                }
                return true
            }

            // Flush any remaining phrase at end of segment.
            if currentPhrase.count >= 2 {
                let phrase = currentPhrase.joined(separator: " ").lowercased()
                phraseCounts[phrase, default: 0] += 1
            }
        }

        return phraseCounts
            .sorted { $0.value > $1.value }
            .prefix(maxPhrases)
            .map(\.key)
    }

    // MARK: - Private Helpers

    private static func languageDisplayName(for code: String) -> String {
        let locale = Locale.current
        return locale.localizedString(forLanguageCode: code) ?? code
    }

    /// Common English stop words filtered from topic extraction.
    private static let stopWords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her",
        "she", "or", "an", "will", "my", "one", "all", "would", "there",
        "their", "what", "so", "up", "out", "if", "about", "who", "get",
        "which", "go", "me", "when", "make", "can", "like", "time", "no",
        "just", "him", "know", "take", "people", "into", "year", "your",
        "good", "some", "could", "them", "see", "other", "than", "then",
        "now", "look", "only", "come", "its", "over", "think", "also",
        "back", "after", "use", "two", "how", "our", "work", "first",
        "well", "way", "even", "new", "want", "because", "any", "these",
        "give", "day", "most", "us", "are", "was", "were", "been", "has",
        "had", "did", "got", "may", "being", "said", "let", "yes", "yeah",
        "okay", "right", "sure", "think", "going", "going", "gonna", "lot",
        "thing", "things", "something", "really", "very", "much", "actually",
        "basically", "kind", "sort", "stuff", "bit", "maybe", "probably"
    ]
}
