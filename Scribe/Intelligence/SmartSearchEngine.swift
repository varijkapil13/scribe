import Foundation
import FoundationModels

// MARK: - SmartSearchEngine

/// Uses Apple's Foundation Models framework (macOS 26+) for natural language
/// search over meeting transcripts.
///
/// Unlike FTS5 keyword search, ``SmartSearchEngine`` understands intent and
/// semantics:
/// - "What was discussed about the Q3 budget?" finds relevant segments even
///   without exact keyword matches.
/// - "Did anyone volunteer for the demo?" understands semantic meaning and
///   identifies commitments.
/// - "Were there disagreements about the timeline?" detects sentiment and
///   conflict.
///
/// All processing happens on-device using Apple Intelligence — no data leaves
/// the Mac. Requires macOS 26+ with Apple Silicon.
///
/// ## Example
/// ```swift
/// let results = try await SmartSearchEngine.search(
///     query: "What decisions were made about the launch date?",
///     transcripts: transcripts.map { ($0.session, $0.segments) }
/// )
/// ```
struct SmartSearchEngine {

    // MARK: - Search Result

    /// A search result containing relevant segments from a single session along
    /// with a natural language answer synthesized from the transcript.
    struct SmartSearchResult: Identifiable, Equatable {

        /// Unique identifier for this result.
        let id: UUID

        /// The session this result was drawn from.
        let sessionId: String

        /// The user-facing title of the session.
        let sessionTitle: String

        /// Transcript segments that are relevant to the query, ordered by
        /// relevance.
        let relevantSegments: [RelevantSegment]

        /// A natural language answer to the query, synthesized from the
        /// matching segments.
        let answer: String

        /// A transcript segment identified as relevant to the search query,
        /// annotated with an explanation of why it matched.
        struct RelevantSegment: Identifiable, Equatable {

            /// Unique identifier for this relevant segment.
            let id: UUID

            /// The speaker who said this segment.
            let speaker: String

            /// The transcribed text of this segment.
            let text: String

            /// The formatted timestamp of this segment (e.g. "[00:05:23]").
            let timestamp: String

            /// A brief explanation of why this segment is relevant to the query.
            let relevanceReason: String
        }
    }

    // MARK: - Smart Search

    /// Search across multiple transcripts using natural language.
    ///
    /// The Foundation Models framework interprets the query intent and finds
    /// segments that are semantically relevant — not just keyword matches. Each
    /// matching session receives a natural language answer summarizing what was
    /// found.
    ///
    /// Results are ranked by relevance and limited to the top 5 sessions.
    ///
    /// - Parameters:
    ///   - query: A natural language search query (e.g. "What was discussed
    ///     about the Q3 budget?").
    ///   - transcripts: An array of session/segment pairs to search over.
    /// - Returns: An array of ``SmartSearchResult`` values, ranked by relevance.
    /// - Throws: ``IntelligenceError/notAvailable`` on systems earlier than
    ///   macOS 26, or ``IntelligenceError/generationFailed(_:)`` if the model
    ///   fails.
    static func search(
        query: String,
        transcripts: [(session: Session, segments: [Segment])]
    ) async throws -> [SmartSearchResult] {


        var results: [SmartSearchResult] = []

        for (session, segments) in transcripts {
            guard !segments.isEmpty else { continue }

            let formattedTranscript = formatTranscriptForPrompt(segments: segments)

            let prompt = """
            You are an intelligent meeting search assistant. A user is searching \
            their meeting transcripts with the following query:

            QUERY: \(query)

            Below is a meeting transcript titled "\(session.title)". Determine \
            whether this transcript contains information relevant to the query.

            If relevant information is found, respond with a JSON object containing:
            - "relevant": true
            - "answer": A concise natural language answer to the query based on \
            this transcript.
            - "segments": An array of the most relevant excerpts (up to 5), each with:
                - "speaker": The speaker name.
                - "text": The exact quote from the transcript.
                - "timestamp": The timestamp from the transcript.
                - "relevanceReason": A brief explanation of why this excerpt matters.

            If the transcript is NOT relevant to the query, respond with:
            - "relevant": false

            Respond ONLY with valid JSON. Do not include markdown code fences.

            TRANSCRIPT:
            \(formattedTranscript)
            """

            let responseText = try await generateResponse(prompt: prompt)

            if let result = try? parseSearchResponse(
                responseText,
                sessionId: session.id,
                sessionTitle: session.title
            ) {
                results.append(result)
            }
        }

        // Limit to top 5 results.
        return Array(results.prefix(5))
    }

    // MARK: - Ask About Session

    /// Ask a natural language question about a specific session's transcript.
    ///
    /// The model analyzes the entire transcript and produces a detailed answer
    /// with supporting quotes. Supports questions such as:
    /// - "What did John say about the timeline?"
    /// - "Were there any disagreements?"
    /// - "Who volunteered for the code review?"
    ///
    /// - Parameters:
    ///   - question: The user's question in natural language.
    ///   - session: The session to query.
    ///   - segments: The transcript segments for the session.
    /// - Returns: A detailed natural language answer with supporting quotes.
    /// - Throws: ``IntelligenceError`` if the model is unavailable or fails.
    static func ask(
        question: String,
        session: Session,
        segments: [Segment]
    ) async throws -> String {


        let formattedTranscript = formatTranscriptForPrompt(segments: segments)

        let prompt = """
        You are a helpful assistant answering questions about a meeting transcript \
        titled "\(session.title)". Answer the following question based ONLY on the \
        transcript content. If the answer is not found in the transcript, say so \
        clearly.

        Include relevant direct quotes from the transcript to support your answer. \
        Format each quote with the speaker name and timestamp.

        QUESTION: \(question)

        TRANSCRIPT:
        \(formattedTranscript)
        """

        return try await generateResponse(prompt: prompt)
    }

    // MARK: - Find Related Sessions

    /// Find sessions that discuss topics similar to a given session.
    ///
    /// The model compares the reference session's content against all other
    /// sessions and identifies topical overlap, returning sessions with an
    /// explanation of how they relate.
    ///
    /// - Parameters:
    ///   - sessionId: The identifier of the reference session.
    ///   - allSessions: All available session/segment pairs to compare against.
    /// - Returns: An array of related sessions paired with a string explaining
    ///   the relationship. Ordered by strength of relation.
    /// - Throws: ``IntelligenceError`` if the model is unavailable or fails.
    static func findRelatedSessions(
        to sessionId: String,
        allSessions: [(Session, [Segment])]
    ) async throws -> [(Session, String)] {


        // Find the reference session and its segments.
        guard let reference = allSessions.first(where: { $0.0.id == sessionId }) else {
            return []
        }

        let referenceTranscript = formatTranscriptForPrompt(segments: reference.1)

        // Build a condensed summary of the reference session for comparison.
        let referenceSummaryPrompt = """
        Summarize the main topics, themes, and key points discussed in this \
        meeting in 3-5 bullet points. Be specific about names, projects, and \
        decisions mentioned.

        Respond with only the bullet points, no other text.

        TRANSCRIPT:
        \(referenceTranscript)
        """

        let referenceSummary = try await generateResponse(prompt: referenceSummaryPrompt)

        // Compare the reference summary against each other session.
        var relatedSessions: [(session: Session, explanation: String, score: Int)] = []

        let otherSessions = allSessions.filter { $0.0.id != sessionId }

        for (session, segments) in otherSessions {
            guard !segments.isEmpty else { continue }

            let candidateTranscript = formatTranscriptForPrompt(segments: segments)

            let comparisonPrompt = """
            You are analyzing whether two meetings are topically related.

            REFERENCE MEETING TOPICS ("\(reference.0.title)"):
            \(referenceSummary)

            CANDIDATE MEETING ("\(session.title)"):
            \(candidateTranscript)

            Determine if the candidate meeting discusses topics related to the \
            reference meeting. Respond with a JSON object:
            - "related": true or false
            - "score": An integer from 1-10 indicating strength of relation \
            (10 = highly related).
            - "explanation": A brief explanation of how the meetings are related \
            (or why they are not).

            Respond ONLY with valid JSON. Do not include markdown code fences.
            """

            let responseText = try await generateResponse(prompt: comparisonPrompt)

            if let parsed = try? parseRelationResponse(responseText),
               parsed.related {
                relatedSessions.append((
                    session: session,
                    explanation: parsed.explanation,
                    score: parsed.score
                ))
            }
        }

        // Sort by relation score descending and return without the score.
        return relatedSessions
            .sorted { $0.score > $1.score }
            .map { ($0.session, $0.explanation) }
    }

    // MARK: - Private Helpers

    /// Format transcript segments into a readable prompt-ready string.
    ///
    /// Each segment is formatted as `[HH:MM:SS] Speaker: text`. When the
    /// transcript exceeds the character budget the middle portion is truncated
    /// on segment boundaries and replaced with a note indicating how many
    /// segments were omitted.
    ///
    /// - Parameter segments: The segments to format.
    /// - Returns: A formatted transcript string suitable for inclusion in a prompt.
    private static func formatTranscriptForPrompt(segments: [Segment]) -> String {
        let formatted = segments.map { segment in
            "\(segment.formattedTimestamp) \(segment.speaker): \(segment.text)"
        }

        let fullText = formatted.joined(separator: "\n")

        // If the transcript is under the character budget, return it in full.
        let maxCharacters = 12_000
        if fullText.count <= maxCharacters {
            return fullText
        }

        // Keep the first and last portions so the model sees the opening and
        // closing of the meeting while staying within budget. Truncate on
        // segment boundaries so the omission count is accurate.
        let halfBudget = maxCharacters / 2

        var prefixLines: [String] = []
        var prefixLength = 0
        for line in formatted {
            let added = line.count + (prefixLines.isEmpty ? 0 : 1)
            if prefixLength + added > halfBudget { break }
            prefixLines.append(line)
            prefixLength += added
        }

        var suffixLines: [String] = []
        var suffixLength = 0
        for line in formatted.reversed() {
            let added = line.count + (suffixLines.isEmpty ? 0 : 1)
            if suffixLength + added > halfBudget { break }
            suffixLines.insert(line, at: 0)
            suffixLength += added
        }

        let omittedSegments = max(0, segments.count - prefixLines.count - suffixLines.count)
        let prefix = prefixLines.joined(separator: "\n")
        let suffix = suffixLines.joined(separator: "\n")

        return """
        \(prefix)

        [...approximately \(omittedSegments) segments omitted for brevity...]

        \(suffix)
        """
    }

    /// Send a prompt to the Foundation Models language model and return the
    /// generated text.
    ///
    /// Creates a ``LanguageModelSession`` and calls its `respond(to:)` method.
    /// All processing happens on-device via Apple Intelligence.
    ///
    /// - Parameter prompt: The prompt string to send to the model.
    /// - Returns: The generated response text.
    /// - Throws: ``IntelligenceError/notAvailable(reason:)`` if Apple
    ///   Intelligence is not available on this device, or
    ///   ``IntelligenceError/generationFailed(_:)`` if the model fails.
    private static func generateResponse(prompt: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw IntelligenceError.notAvailable(reason: String(describing: reason))
        }

        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw IntelligenceError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Response Parsing

    /// Parse a search response JSON string into a ``SmartSearchResult``, or
    /// return `nil` if the transcript was not relevant to the query.
    ///
    /// - Parameters:
    ///   - responseText: Raw JSON string from the model.
    ///   - sessionId: The session identifier.
    ///   - sessionTitle: The session title.
    /// - Returns: A ``SmartSearchResult`` if the session was relevant, or `nil`.
    /// - Throws: ``IntelligenceError/parsingFailed`` if the JSON is malformed.
    private static func parseSearchResponse(
        _ responseText: String,
        sessionId: String,
        sessionTitle: String
    ) throws -> SmartSearchResult? {
        guard let data = cleanJSONString(responseText).data(using: .utf8) else {
            throw IntelligenceError.parsingFailed
        }

        let decoded = try JSONDecoder().decode(RawSearchResponse.self, from: data)

        guard decoded.relevant else { return nil }

        let relevantSegments = decoded.segments?.map { raw in
            SmartSearchResult.RelevantSegment(
                id: UUID(),
                speaker: raw.speaker,
                text: raw.text,
                timestamp: raw.timestamp,
                relevanceReason: raw.relevanceReason ?? ""
            )
        } ?? []

        return SmartSearchResult(
            id: UUID(),
            sessionId: sessionId,
            sessionTitle: sessionTitle,
            relevantSegments: relevantSegments,
            answer: decoded.answer ?? ""
        )
    }

    /// Parse a relation comparison response from the model.
    ///
    /// - Parameter responseText: Raw JSON string from the model.
    /// - Returns: A parsed relation result.
    /// - Throws: ``IntelligenceError/parsingFailed`` if the JSON is malformed.
    private static func parseRelationResponse(
        _ responseText: String
    ) throws -> RawRelationResponse {
        guard let data = cleanJSONString(responseText).data(using: .utf8) else {
            throw IntelligenceError.parsingFailed
        }

        do {
            return try JSONDecoder().decode(RawRelationResponse.self, from: data)
        } catch {
            throw IntelligenceError.parsingFailed
        }
    }

    /// Strip markdown code fences and leading/trailing whitespace from a JSON
    /// response so that ``JSONDecoder`` can parse it cleanly.
    private static func cleanJSONString(_ string: String) -> String {
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove ```json ... ``` fences if the model included them despite
        // being asked not to.
        if cleaned.hasPrefix("```") {
            // Drop the opening fence line.
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Drop the closing fence.
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }
}

// MARK: - Private Decodable Helpers

/// Intermediate model for decoding the search response JSON from the model.
private struct RawSearchResponse: Decodable {
    let relevant: Bool
    let answer: String?
    let segments: [RawSearchSegment]?
}

/// Intermediate model for decoding a single relevant segment from the search response.
private struct RawSearchSegment: Decodable {
    let speaker: String
    let text: String
    let timestamp: String
    let relevanceReason: String?
}

/// Intermediate model for decoding the relation comparison response.
private struct RawRelationResponse: Decodable {
    let related: Bool
    let score: Int
    let explanation: String
}
