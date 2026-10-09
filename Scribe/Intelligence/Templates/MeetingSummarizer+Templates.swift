import Foundation
import FoundationModels

// MARK: - Template-driven generation
//
// Free-form markdown generation on top of the on-device model: template
// summaries, "Enhance notes" and recipes. The structured `summarize(...)`
// JSON flow in `MeetingSummarizer.swift` is untouched. Every entry point
// condenses long transcripts first (see `TranscriptBudget`) so prompts stay
// inside the on-device context window.
extension MeetingSummarizer {

    /// Renders a markdown summary of the transcript that follows `template`.
    static func renderSummary(
        template: SummaryTemplate,
        title: String,
        segments: [(speaker: String, text: String, timestamp: String)]
    ) async throws -> String {
        let transcript = try await condensedTranscript(
            segments: segments,
            budget: TranscriptBudget.summaryBudget
        )
        guard !transcript.isEmpty else {
            throw IntelligenceError.generationFailed("The transcript is empty.")
        }
        let output = try await generateText(
            instructions: NoteAIPromptBuilder.templateInstructions(template),
            prompt: NoteAIPromptBuilder.templatePrompt(title: title, transcript: transcript)
        )
        return NoteAIPromptBuilder.cleanMarkdownOutput(output)
    }

    /// Expands the user's own notes with details from the transcript. Lines
    /// the model adds start with `NoteAIPromptBuilder.aiLinePrefix`.
    static func enhanceNotes(
        userNotes: String,
        title: String,
        segments: [(speaker: String, text: String, timestamp: String)]
    ) async throws -> String {
        let transcript = try await condensedTranscript(
            segments: segments,
            budget: TranscriptBudget.enhanceTranscriptBudget
        )
        guard !transcript.isEmpty else {
            throw IntelligenceError.generationFailed("The transcript is empty.")
        }
        let output = try await generateText(
            instructions: NoteAIPromptBuilder.enhanceInstructions,
            prompt: NoteAIPromptBuilder.enhancePrompt(
                userNotes: userNotes,
                title: title,
                transcript: transcript
            )
        )
        return NoteAIPromptBuilder.cleanMarkdownOutput(output)
    }

    /// Runs a custom recipe prompt against the transcript (+ the user's notes).
    static func runRecipe(
        _ recipe: NoteRecipe,
        title: String,
        noteBody: String,
        segments: [(speaker: String, text: String, timestamp: String)]
    ) async throws -> String {
        let transcript = try await condensedTranscript(
            segments: segments,
            budget: TranscriptBudget.recipeTranscriptBudget
        )
        guard !transcript.isEmpty || !noteBody.isEmpty else {
            throw IntelligenceError.generationFailed("There is no transcript or note text to work with.")
        }
        let output = try await generateText(
            instructions: NoteAIPromptBuilder.recipeInstructions,
            prompt: NoteAIPromptBuilder.recipePrompt(
                recipe: recipe,
                title: title,
                transcript: transcript,
                noteBody: noteBody
            )
        )
        return NoteAIPromptBuilder.cleanMarkdownOutput(output)
    }

    // MARK: - Helpers

    /// The transcript as prompt lines, condensed chunk-by-chunk by the model
    /// when it exceeds `budget` characters.
    static func condensedTranscript(
        segments: [(speaker: String, text: String, timestamp: String)],
        budget: Int
    ) async throws -> String {
        let lines = TranscriptBudget.formatLines(segments)
        return try await TranscriptBudget.condense(lines: lines, budget: budget) { chunk in
            try await MeetingSummarizer.generateText(
                instructions: NoteAIPromptBuilder.condenseInstructions,
                prompt: NoteAIPromptBuilder.condensePrompt(chunk: chunk)
            )
        }
    }

    /// One-shot on-device generation with a fresh session per call (no
    /// transcript history accumulates in the context window).
    static func generateText(instructions: String, prompt: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw IntelligenceError.notAvailable(reason: String(describing: reason))
        }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw IntelligenceError.generationFailed(error.localizedDescription)
        }
    }
}
