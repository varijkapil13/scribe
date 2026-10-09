import Foundation

// MARK: - Vault templates (summary templates + recipes)
//
// Templates live as plain markdown files inside the notes vault:
//
//     <vault>/Templates/Summaries/<id>.md   — summary templates
//     <vault>/Templates/Recipes/<id>.md     — custom prompts ("recipes")
//
// Each file is a tiny frontmatter block followed by a markdown body:
//
//     ---
//     name: 1:1
//     description: Weekly one-on-one
//     match: 1:1, one on one, 1on1
//     ---
//     <instructions + section headings>
//
// Everything in this file is pure (Foundation only) so it is unit-testable
// without Apple Intelligence or a vault on disk.

/// Parsed frontmatter + body of a template file. Keys are lowercased.
struct TemplateFileContents: Equatable, Sendable {
    var fields: [String: String]
    var body: String
}

enum TemplateFileParser {

    /// Splits `contents` into a simple `key: value` frontmatter map and the
    /// remaining body. Tolerates a missing frontmatter block (the whole file
    /// becomes the body), CRLF line endings, quoted values, inline YAML lists
    /// (`[a, b]`) and block lists (`- a` lines under an empty key, which are
    /// joined with ", ").
    static func parse(_ raw: String) -> TemplateFileContents {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // Skip leading blank lines before the opening fence.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---",
              let closeIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else {
            return TemplateFileContents(
                fields: [:],
                body: normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var fields: [String: String] = [:]
        var lastKey: String?
        for line in lines[1..<closeIndex] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), let key = lastKey {
                let item = unquote(String(trimmed.dropFirst(2)))
                let existing = fields[key] ?? ""
                fields[key] = existing.isEmpty ? item : existing + ", " + item
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            } else {
                value = unquote(value)
            }
            fields[key] = value
            lastKey = key
        }
        let body = lines[(closeIndex + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TemplateFileContents(fields: fields, body: body)
    }

    /// Serializes a field list (ordered) + body back into a template file.
    static func serialize(fields: [(key: String, value: String)], body: String) -> String {
        var out = "---\n"
        for field in fields where !field.value.isEmpty {
            out += "\(field.key): \(field.value)\n"
        }
        out += "---\n\n"
        out += body.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n"
        return out
    }

    /// Comma-separated list → trimmed, lowercased, non-empty items.
    static func splitList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// A filesystem-safe, lowercased id (`"Sales / Customer call"` →
    /// `"sales-customer-call"`). Falls back to `"template"` when nothing
    /// usable remains.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "template" : out
    }

    private static func unquote(_ value: String) -> String {
        var v = value
        if v.count >= 2,
           (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}

// MARK: - SummaryTemplate

/// A summary template: instructions + section headings the on-device model
/// follows when rendering a markdown summary of a transcript.
struct SummaryTemplate: Equatable, Identifiable, Sendable {
    /// Stable id = file name without `.md`.
    let id: String
    var name: String
    var description: String
    /// Lowercased keywords matched against meeting / note titles by
    /// `TemplateSelector` (e.g. `["1:1", "one on one"]`).
    var matchKeywords: [String]
    /// Markdown body: free-form instructions followed by the section headings.
    var body: String

    static func parse(_ raw: String, id: String) -> SummaryTemplate {
        let parsed = TemplateFileParser.parse(raw)
        let name = parsed.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        return SummaryTemplate(
            id: id,
            name: name,
            description: parsed.fields["description"] ?? "",
            matchKeywords: TemplateFileParser.splitList(parsed.fields["match"]),
            body: parsed.body
        )
    }

    func serialized() -> String {
        TemplateFileParser.serialize(
            fields: [
                (key: "name", value: name),
                (key: "description", value: description),
                (key: "match", value: matchKeywords.joined(separator: ", "))
            ],
            body: body
        )
    }

    /// The `## …` / `### …` headings in the body, in order — what the summary
    /// must contain.
    var sectionHeadings: [String] {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") }
            .map { line in
                String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }
}

// MARK: - NoteRecipe

/// A custom prompt ("recipe") run against a transcript + note.
struct NoteRecipe: Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var description: String
    /// The prompt body sent to the model.
    var prompt: String

    static func parse(_ raw: String, id: String) -> NoteRecipe {
        let parsed = TemplateFileParser.parse(raw)
        let name = parsed.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        return NoteRecipe(
            id: id,
            name: name,
            description: parsed.fields["description"] ?? "",
            prompt: parsed.body
        )
    }

    func serialized() -> String {
        TemplateFileParser.serialize(
            fields: [
                (key: "name", value: name),
                (key: "description", value: description)
            ],
            body: prompt
        )
    }
}

// MARK: - Built-ins

enum BuiltInTemplates {

    static let defaultTemplateId = "general"

    private static let commonRules = """
    Write the meeting notes in markdown using exactly the section headings below, in this order. \
    Use short, specific bullet points. Use only information from the transcript; never invent names, \
    numbers or dates. If a section has nothing relevant, write "None." under it. \
    Write action items as "- [ ] Owner: task (due date if mentioned)".
    """

    static let summaries: [SummaryTemplate] = [
        SummaryTemplate(
            id: "general",
            name: "General",
            description: "Balanced notes for any meeting.",
            matchKeywords: [],
            body: """
            \(commonRules)

            ## Summary
            ## Key points
            ## Decisions
            ## Action items
            ## Open questions
            """
        ),
        SummaryTemplate(
            id: "one-on-one",
            name: "1:1",
            description: "One-on-one between a manager and a report, or two peers.",
            matchKeywords: ["1:1", "1-1", "1on1", "one on one", "one-on-one", "catch up", "check-in", "check in"],
            body: """
            \(commonRules) Keep a supportive, private tone.

            ## Highlights
            ## Blockers and concerns
            ## Feedback
            ## Growth and career
            ## Action items
            """
        ),
        SummaryTemplate(
            id: "standup",
            name: "Standup",
            description: "Daily standup or sync: progress, plans, blockers.",
            matchKeywords: ["standup", "stand-up", "stand up", "daily", "scrum", "sync"],
            body: """
            \(commonRules) Group updates per person where the speaker is clear.

            ## Yesterday
            ## Today
            ## Blockers
            ## Action items
            """
        ),
        SummaryTemplate(
            id: "interview",
            name: "Interview",
            description: "Candidate interview: signals, strengths, concerns.",
            matchKeywords: ["interview", "screen", "screening", "candidate", "hiring"],
            body: """
            \(commonRules) Be factual and avoid judging protected characteristics.

            ## Candidate background
            ## Questions asked
            ## Strengths
            ## Concerns
            ## Overall impression
            ## Next steps
            """
        ),
        SummaryTemplate(
            id: "sales-call",
            name: "Sales / Customer call",
            description: "Customer or prospect call: needs, objections, next steps.",
            matchKeywords: ["sales", "customer", "client", "prospect", "demo", "discovery", "account", "deal"],
            body: """
            \(commonRules)

            ## Customer context
            ## Needs and pain points
            ## Objections and concerns
            ## Pricing and timeline
            ## Next steps
            ## Action items
            """
        ),
        SummaryTemplate(
            id: "brainstorm",
            name: "Brainstorm",
            description: "Ideation session: ideas, themes, what to pursue.",
            matchKeywords: ["brainstorm", "ideation", "workshop", "ideas", "planning"],
            body: """
            \(commonRules) Capture every distinct idea, even the ones that were set aside.

            ## Problem statement
            ## Ideas
            ## Themes
            ## Ideas to pursue
            ## Action items
            """
        )
    ]

    static let recipes: [NoteRecipe] = [
        NoteRecipe(
            id: "follow-up-email",
            name: "Follow-up email",
            description: "Draft a follow-up email to the attendees.",
            prompt: """
            Write a short, friendly follow-up email to the meeting attendees. Start with a line \
            "Subject: …". Recap the purpose in one sentence, list the decisions, then the action items \
            with owners and dates where mentioned. Plain text, no JSON.
            """
        ),
        NoteRecipe(
            id: "decisions-and-owners",
            name: "Decisions & owners",
            description: "List every decision and who owns the follow-through.",
            prompt: """
            List every decision made in the meeting as markdown bullets in the form \
            "- Decision — Owner (deadline if mentioned)". Write "Owner: unclear" when nobody took it. \
            If no decisions were made, say so.
            """
        ),
        NoteRecipe(
            id: "risks-and-open-questions",
            name: "Risks & open questions",
            description: "Surface risks, unknowns and unanswered questions.",
            prompt: """
            Identify the risks, unknowns and unanswered questions raised (or implied) in the meeting. \
            Use two markdown sections, "## Risks" and "## Open questions", with one bullet each. For \
            each risk add a short note on impact. Only use information from the transcript.
            """
        )
    ]
}
