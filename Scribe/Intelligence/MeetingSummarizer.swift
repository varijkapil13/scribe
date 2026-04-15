import Foundation
import FoundationModels

// MARK: - Data Models

/// A structured meeting summary produced by on-device Apple Intelligence.
///
/// Contains an executive summary, key decisions, action items, topics, and
/// follow-up questions extracted from a meeting transcript.
struct MeetingSummary: Codable, Equatable, Identifiable {

    /// Unique identifier for this summary.
    let id: UUID
    /// The session that was summarized.
    let sessionId: String
    /// A 2-4 paragraph executive summary of the meeting.
    let summary: String
    /// Key decisions made during the meeting.
    let keyDecisions: [String]
    /// Action items extracted from the transcript.
    let actionItems: [ActionItem]
    /// Main topics discussed in the meeting.
    let keyTopics: [String]
    /// Open questions that need follow-up.
    let followUpQuestions: [String]
    /// When this summary was generated.
    let createdAt: Date
}

/// An action item extracted from a meeting transcript.
///
/// Each action item includes the original transcript text that led to its
/// extraction, making it easy to verify and provide context.
struct ActionItem: Codable, Equatable, Identifiable, Hashable {

    /// Unique identifier for this action item.
    let id: UUID
    /// What needs to be done.
    let description: String
    /// Who should do it, if mentioned in the transcript.
    let assignee: String?
    /// When it is due, if mentioned in the transcript.
    let deadline: String?
    /// Inferred priority based on language cues and context.
    let priority: Priority?
    /// The original transcript text that led to this action item.
    let sourceText: String

    /// Priority level for an action item.
    enum Priority: String, Codable, CaseIterable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
    }
}

// MARK: - MeetingSummarizer

/// Uses Apple's Foundation Models framework to generate meeting summaries,
/// extract action items, and answer questions about transcripts.
///
/// All processing happens on-device using Apple Intelligence — no data leaves
/// the Mac. Requires macOS 26+ with Apple Silicon.
///
/// ## Example
/// ```swift
/// let summary = try await MeetingSummarizer.summarize(
///     sessionId: session.id,
///     title: session.title,
///     segments: segments.map { ($0.speaker, $0.text, $0.formattedTimestamp) }
/// )
/// ```
struct MeetingSummarizer {

    // MARK: - Summarize Meeting

    /// Generate a comprehensive summary of a meeting transcript.
    ///
    /// The summary includes an executive overview, key decisions, extracted
    /// action items with assignees and deadlines where mentioned, main topics,
    /// and follow-up questions.
    ///
    /// - Parameters:
    ///   - sessionId: The unique identifier for the transcription session.
    ///   - title: The user-facing title of the meeting.
    ///   - segments: An array of transcript segments, each containing a speaker
    ///     label, the transcribed text, and a formatted timestamp string.
    /// - Returns: A fully populated ``MeetingSummary``.
    /// - Throws: ``IntelligenceError/notAvailable`` on systems earlier than
    ///   macOS 26, or ``IntelligenceError/generationFailed(_:)`` if the model
    ///   fails to produce a usable response.
    static func summarize(
        sessionId: String,
        title: String,
        segments: [(speaker: String, text: String, timestamp: String)]
    ) async throws -> MeetingSummary {


        let transcript = formatTranscriptForPrompt(segments: segments)

        let prompt = """
        You are an expert meeting analyst. Analyze the following meeting transcript \
        titled "\(title)" and produce a JSON object with these exact keys:

        - "summary": A 2-4 paragraph executive summary covering the main points, \
        outcomes, and overall tone of the meeting.
        - "keyDecisions": An array of strings, each a decision that was made.
        - "actionItems": An array of objects, each with:
            - "description": What needs to be done.
            - "assignee": Who should do it (null if not mentioned).
            - "deadline": When it is due (null if not mentioned).
            - "priority": "High", "Medium", or "Low" based on urgency cues.
            - "sourceText": The exact transcript quote that led to this item.
        - "keyTopics": An array of the main topics discussed.
        - "followUpQuestions": An array of open questions needing follow-up.

        Respond ONLY with valid JSON. Do not include markdown code fences.

        TRANSCRIPT:
        \(transcript)
        """

        let responseText = try await generateResponse(prompt: prompt)
        return try parseSummaryResponse(responseText, sessionId: sessionId)
    }

    // MARK: - Extract Action Items Only

    /// Extract action items from a transcript without generating a full summary.
    ///
    /// The prompt is tuned specifically for identifying commitments, task
    /// assignments, volunteer offers, and deadlines.
    ///
    /// - Parameter segments: Transcript segments to analyze.
    /// - Returns: An array of ``ActionItem`` values extracted from the transcript.
    /// - Throws: ``IntelligenceError`` if the model is unavailable or fails.
    static func extractActionItems(
        from segments: [(speaker: String, text: String, timestamp: String)]
    ) async throws -> [ActionItem] {


        let transcript = formatTranscriptForPrompt(segments: segments)

        let prompt = """
        You are a meticulous meeting analyst focused on identifying action items. \
        Review the transcript below and extract every commitment, task assignment, \
        volunteer offer, or follow-up that was agreed upon.

        For each action item, produce a JSON object with:
        - "description": What needs to be done.
        - "assignee": Who should do it (null if unclear).
        - "deadline": When it is due (null if not stated).
        - "priority": "High", "Medium", or "Low".
        - "sourceText": The verbatim transcript excerpt.

        Return a JSON array of these objects. Respond ONLY with valid JSON. \
        Do not include markdown code fences.

        TRANSCRIPT:
        \(transcript)
        """

        let responseText = try await generateResponse(prompt: prompt)
        return try parseActionItemsResponse(responseText)
    }

    // MARK: - Generate Follow-Up Email

    /// Generate a professional follow-up email based on a meeting summary.
    ///
    /// The email includes a recap of the discussion, decisions reached, and
    /// outstanding action items with their assignees.
    ///
    /// - Parameters:
    ///   - summary: The meeting summary to base the email on.
    ///   - recipientContext: Optional context about the recipients to adjust
    ///     tone (e.g. "executive leadership", "engineering team").
    /// - Returns: A ready-to-send email body as a plain-text string.
    /// - Throws: ``IntelligenceError`` if the model is unavailable or fails.
    static func generateFollowUpEmail(
        summary: MeetingSummary,
        recipientContext: String? = nil
    ) async throws -> String {


        let decisionsFormatted = summary.keyDecisions.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let actionItemsFormatted = summary.actionItems.enumerated()
            .map { index, item in
                var line = "\(index + 1). \(item.description)"
                if let assignee = item.assignee { line += " (Owner: \(assignee))" }
                if let deadline = item.deadline { line += " [Due: \(deadline)]" }
                return line
            }
            .joined(separator: "\n")

        let followUpsFormatted = summary.followUpQuestions.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        var toneInstruction = ""
        if let context = recipientContext {
            toneInstruction = "\nAdjust the tone for the audience: \(context)."
        }

        let prompt = """
        Write a professional follow-up email summarizing a meeting. \
        Use a clear, concise, and friendly tone.\(toneInstruction)

        MEETING SUMMARY:
        \(summary.summary)

        KEY DECISIONS:
        \(decisionsFormatted.isEmpty ? "None recorded." : decisionsFormatted)

        ACTION ITEMS:
        \(actionItemsFormatted.isEmpty ? "None recorded." : actionItemsFormatted)

        OPEN QUESTIONS:
        \(followUpsFormatted.isEmpty ? "None." : followUpsFormatted)

        Include a subject line at the top prefixed with "Subject: ". \
        Do not include any JSON. Write the email as plain text.
        """

        return try await generateResponse(prompt: prompt)
    }

    // MARK: - Answer Question About Transcript

    /// Answer a natural language question about a meeting transcript.
    ///
    /// Supports questions such as:
    /// - "What did John say about the timeline?"
    /// - "Were there any disagreements?"
    /// - "Who volunteered for the code review?"
    ///
    /// The answer includes relevant quotes from the transcript where applicable.
    ///
    /// - Parameters:
    ///   - question: The user's question in natural language.
    ///   - segments: The transcript segments to search over.
    /// - Returns: A natural language answer with supporting quotes.
    /// - Throws: ``IntelligenceError`` if the model is unavailable or fails.
    static func answerQuestion(
        _ question: String,
        segments: [(speaker: String, text: String, timestamp: String)]
    ) async throws -> String {


        let transcript = formatTranscriptForPrompt(segments: segments)

        let prompt = """
        You are a helpful assistant answering questions about a meeting transcript. \
        Answer the following question based ONLY on the transcript content. If the \
        answer is not found in the transcript, say so clearly.

        Include relevant direct quotes from the transcript to support your answer. \
        Format quotes with the speaker name and timestamp.

        QUESTION: \(question)

        TRANSCRIPT:
        \(transcript)
        """

        return try await generateResponse(prompt: prompt)
    }

    // MARK: - Private Helpers

    /// Format transcript segments into a readable prompt-ready string.
    ///
    /// Each segment is formatted as `[timestamp] Speaker: text`. When the
    /// transcript exceeds the length threshold, the middle portion is truncated
    /// and replaced with a note indicating omitted content.
    ///
    /// - Parameter segments: The segments to format.
    /// - Returns: A formatted transcript string suitable for inclusion in a prompt.
    private static func formatTranscriptForPrompt(
        segments: [(speaker: String, text: String, timestamp: String)]
    ) -> String {
        let formatted = segments.map { segment in
            "\(segment.timestamp) \(segment.speaker): \(segment.text)"
        }

        let fullText = formatted.joined(separator: "\n")

        // If the transcript is under the character budget, return it in full.
        let maxCharacters = 12_000
        if fullText.count <= maxCharacters {
            return fullText
        }

        // Keep the first and last portions so the model sees the opening and
        // closing of the meeting while staying within budget.
        let halfBudget = maxCharacters / 2
        let prefix = String(fullText.prefix(halfBudget))
        let suffix = String(fullText.suffix(halfBudget))

        let omittedCount = segments.count - (formatted.count)
        return """
        \(prefix)

        [...approximately \(omittedCount) segments omitted for brevity...]

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
    /// - Throws: ``IntelligenceError/generationFailed(_:)`` if the model fails.
    private static func generateResponse(prompt: String) async throws -> String {
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw IntelligenceError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Response Parsing

    /// Parse a JSON response string into a ``MeetingSummary``.
    ///
    /// The expected JSON shape matches the schema described in the summarization
    /// prompt. Missing optional fields are handled gracefully.
    ///
    /// - Parameters:
    ///   - responseText: Raw JSON string from the model.
    ///   - sessionId: The session identifier to embed in the summary.
    /// - Returns: A populated ``MeetingSummary``.
    /// - Throws: ``IntelligenceError/parsingFailed`` if the JSON is malformed.
    private static func parseSummaryResponse(
        _ responseText: String,
        sessionId: String
    ) throws -> MeetingSummary {
        guard let data = cleanJSONString(responseText).data(using: .utf8) else {
            throw IntelligenceError.parsingFailed
        }

        do {
            let decoded = try JSONDecoder().decode(RawSummaryResponse.self, from: data)

            let actionItems = decoded.actionItems?.map { raw in
                ActionItem(
                    id: UUID(),
                    description: raw.description,
                    assignee: raw.assignee,
                    deadline: raw.deadline,
                    priority: raw.priority.flatMap { ActionItem.Priority(rawValue: $0) },
                    sourceText: raw.sourceText ?? ""
                )
            } ?? []

            return MeetingSummary(
                id: UUID(),
                sessionId: sessionId,
                summary: decoded.summary,
                keyDecisions: decoded.keyDecisions ?? [],
                actionItems: actionItems,
                keyTopics: decoded.keyTopics ?? [],
                followUpQuestions: decoded.followUpQuestions ?? [],
                createdAt: Date()
            )
        } catch {
            throw IntelligenceError.parsingFailed
        }
    }

    /// Parse a JSON response string into an array of ``ActionItem``.
    ///
    /// - Parameter responseText: Raw JSON array string from the model.
    /// - Returns: An array of ``ActionItem`` values.
    /// - Throws: ``IntelligenceError/parsingFailed`` if the JSON is malformed.
    private static func parseActionItemsResponse(
        _ responseText: String
    ) throws -> [ActionItem] {
        guard let data = cleanJSONString(responseText).data(using: .utf8) else {
            throw IntelligenceError.parsingFailed
        }

        do {
            let rawItems = try JSONDecoder().decode([RawActionItem].self, from: data)
            return rawItems.map { raw in
                ActionItem(
                    id: UUID(),
                    description: raw.description,
                    assignee: raw.assignee,
                    deadline: raw.deadline,
                    priority: raw.priority.flatMap { ActionItem.Priority(rawValue: $0) },
                    sourceText: raw.sourceText ?? ""
                )
            }
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

/// Intermediate model for decoding the summary JSON response from the model.
private struct RawSummaryResponse: Decodable {
    let summary: String
    let keyDecisions: [String]?
    let actionItems: [RawActionItem]?
    let keyTopics: [String]?
    let followUpQuestions: [String]?
}

/// Intermediate model for decoding a single action item from the model's JSON.
private struct RawActionItem: Decodable {
    let description: String
    let assignee: String?
    let deadline: String?
    let priority: String?
    let sourceText: String?
}

// MARK: - IntelligenceError

/// Errors that can occur when using Apple Intelligence features.
enum IntelligenceError: LocalizedError {

    /// The language model failed to generate a response.
    case generationFailed(String)
    /// The model's response could not be parsed into the expected format.
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .generationFailed(let detail):
            return "Generation failed: \(detail)"
        case .parsingFailed:
            return "Failed to parse the AI response."
        }
    }
}
