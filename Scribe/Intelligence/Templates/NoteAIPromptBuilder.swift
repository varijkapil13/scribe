import Foundation

/// Pure prompt construction for template summaries, "Enhance notes", recipes
/// and transcript condensing. Kept free of FoundationModels so it is testable.
enum NoteAIPromptBuilder {

    /// Prefix that marks a line the model added during "Enhance notes". Placed
    /// after any list marker / indentation: `- › detail from the transcript`.
    static let aiLinePrefix = "› "

    // MARK: - Condensing

    static let condenseInstructions = """
    You condense part of a meeting transcript into dense factual notes. Keep names, numbers, \
    dates, decisions, commitments and open questions. Drop small talk and filler. \
    Reply with plain markdown bullets only, at most about 15 bullets.
    """

    static func condensePrompt(chunk: String) -> String {
        """
        TRANSCRIPT PART:
        \(chunk)
        """
    }

    // MARK: - Template summary

    static func templateInstructions(_ template: SummaryTemplate) -> String {
        """
        You are an expert meeting note-taker. Follow this template exactly:

        \(template.body)

        Reply with the markdown notes only — no preamble, no closing remarks, no code fences.
        """
    }

    static func templatePrompt(title: String, transcript: String) -> String {
        """
        MEETING: \(title.isEmpty ? "Untitled" : title)

        TRANSCRIPT (may be condensed):
        \(transcript)
        """
    }

    // MARK: - Enhance notes

    static let enhanceInstructions = """
    You improve a person's own meeting notes using the meeting transcript. \
    Rules:
    1. The person's notes are the skeleton. Keep every one of their lines, their headings, \
    their order and their wording. Never delete or reword their lines.
    2. Under or after their lines, add short bullet points with concrete details from the \
    transcript (names, numbers, decisions, owners, dates) that expand on what they wrote.
    3. Start the text of every line YOU add with "\(aiLinePrefix)" right after the bullet marker, \
    for example "  - \(aiLinePrefix)Budget approved at 40k by Dana".
    4. Only add facts supported by the transcript. If something important is missing from the \
    notes, add it at the end under "## Also discussed".
    Reply with the full enhanced notes in markdown only — no preamble and no code fences.
    """

    static func enhancePrompt(userNotes: String, title: String, transcript: String) -> String {
        """
        MEETING: \(title.isEmpty ? "Untitled" : title)

        MY NOTES:
        \(TranscriptBudget.truncate(userNotes, maxChars: TranscriptBudget.enhanceNotesBudget))

        TRANSCRIPT (may be condensed):
        \(transcript)
        """
    }

    /// True when `line` was added by the model during "Enhance notes" (its
    /// text, after indentation / list / checkbox markers, starts with `›`).
    static func isAIAddedLine(_ line: String) -> Bool {
        var rest = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] where rest.hasPrefix(marker) {
            rest = rest.dropFirst(marker.count)
            break
        }
        if let first = rest.first, first.isNumber {
            let afterDigits = rest.drop(while: { $0.isNumber })
            if afterDigits.hasPrefix(". ") { rest = afterDigits.dropFirst(2) }
        }
        return rest.hasPrefix("›")
    }

    // MARK: - Recipes

    static let recipeInstructions = """
    You are a helpful assistant working on a meeting. Use only the meeting transcript and the \
    person's notes provided. If the information isn't there, say so. Reply in markdown \
    without code fences.
    """

    static func recipePrompt(recipe: NoteRecipe, title: String, transcript: String, noteBody: String) -> String {
        let notes = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSection = notes.isEmpty
            ? ""
            : "\n\nMY NOTES:\n" + TranscriptBudget.truncate(notes, maxChars: TranscriptBudget.recipeNoteBudget)
        return """
        TASK:
        \(recipe.prompt)

        MEETING: \(title.isEmpty ? "Untitled" : title)\(notesSection)

        TRANSCRIPT (may be condensed):
        \(transcript)
        """
    }

    // MARK: - Output cleanup

    /// Strips a wrapping ```` ``` ```` / ```` ```markdown ```` fence and
    /// surrounding whitespace from model output.
    static func cleanMarkdownOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            } else {
                text = ""
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
