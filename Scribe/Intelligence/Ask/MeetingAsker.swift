// Scribe/Intelligence/Ask/MeetingAsker.swift
import Foundation

/// The outcome of asking a question across meetings.
struct AskAnswer: Equatable, Sendable {
    var question: String
    var scope: AskScope
    /// The evidence the answer is grounded in.
    var retrieval: RetrievalResult
    /// The model's answer, or a snippet digest when the model wasn't used.
    var answer: String
    /// True when `answer` came from the on-device model.
    var usedModel: Bool
    /// Explains why the model wasn't used / failed, when relevant.
    var notice: String?
}

/// Glue between retrieval and the on-device model, shared by the Ask view
/// and the `ask_meetings` MCP tool.
enum MeetingAsker {

    /// Retrieves evidence for `question` in `scope` and, when Apple
    /// Intelligence is available and `generateAnswer` is true, asks the model
    /// to answer from it. Never throws: failures degrade to a snippet digest
    /// plus a `notice`.
    static func ask(question: String,
                    scope: AskScope,
                    retriever: MeetingRetriever = MeetingRetriever(),
                    generateAnswer: Bool = true) async -> AskAnswer {
        let retrieval: RetrievalResult
        do {
            retrieval = try await Task.detached(priority: .userInitiated) {
                try retriever.retrieve(question: question, scope: scope)
            }.value
        } catch {
            return AskAnswer(question: question, scope: scope, retrieval: .empty,
                             answer: "Search failed.", usedModel: false,
                             notice: error.localizedDescription)
        }

        guard !retrieval.snippets.isEmpty else {
            return AskAnswer(question: question, scope: scope, retrieval: retrieval,
                             answer: MeetingRetrieval.fallbackAnswer(snippets: []),
                             usedModel: false, notice: nil)
        }

        guard generateAnswer else {
            return AskAnswer(question: question, scope: scope, retrieval: retrieval,
                             answer: MeetingRetrieval.fallbackAnswer(snippets: retrieval.snippets),
                             usedModel: false, notice: nil)
        }

        let availability = AppleIntelligenceAvailability.current
        guard availability.isAvailable else {
            var reason = "Apple Intelligence isn't available right now."
            if case .unavailable(let detail) = availability { reason = detail }
            return AskAnswer(question: question, scope: scope, retrieval: retrieval,
                             answer: MeetingRetrieval.fallbackAnswer(snippets: retrieval.snippets),
                             usedModel: false,
                             notice: "\(reason) Showing the most relevant passages instead.")
        }

        let prompt = MeetingRetrieval.buildPrompt(question: question,
                                                  context: retrieval.context,
                                                  scopeLabel: scope.label)
        do {
            let text = try await SmartSearchEngine.answerAcrossMeetings(prompt: prompt)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return AskAnswer(question: question, scope: scope, retrieval: retrieval,
                             answer: trimmed.isEmpty ? MeetingRetrieval.fallbackAnswer(snippets: retrieval.snippets) : trimmed,
                             usedModel: !trimmed.isEmpty, notice: nil)
        } catch {
            return AskAnswer(question: question, scope: scope, retrieval: retrieval,
                             answer: MeetingRetrieval.fallbackAnswer(snippets: retrieval.snippets),
                             usedModel: false,
                             notice: "Couldn't generate an answer (\(error.localizedDescription)). Showing the most relevant passages instead.")
        }
    }
}
