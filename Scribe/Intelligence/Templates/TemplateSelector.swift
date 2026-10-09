import Foundation

/// UserDefaults keys + typed accessors for the Templates settings pane.
enum TemplateSettings {
    /// String — id of the default summary template (`"general"` when unset).
    static let defaultTemplateKey = "summaryTemplates.defaultTemplateId"
    /// Bool (default true) — pick a template from the meeting title keywords.
    static let autoPickKey = "summaryTemplates.autoPickFromTitle"
    /// Bool (default false) — automatic summaries also write a template block
    /// into the session's note.
    static let useForAutoSummaryKey = "summaryTemplates.useForAutoSummary"

    static var defaultTemplateId: String {
        let raw = UserDefaults.standard.string(forKey: defaultTemplateKey) ?? ""
        return raw.isEmpty ? BuiltInTemplates.defaultTemplateId : raw
    }

    static var autoPick: Bool {
        UserDefaults.standard.object(forKey: autoPickKey) as? Bool ?? true
    }

    static var useForAutoSummary: Bool {
        UserDefaults.standard.bool(forKey: useForAutoSummaryKey)
    }
}

/// Picks a summary template for a meeting. Pure.
enum TemplateSelector {

    /// Returns the best template for `titles` (session title, note title,
    /// calendar event title — any order, blanks ignored).
    ///
    /// With `autoPick`, the template whose `match` keywords hit the most
    /// titles wins (ties → the longer matching keyword, then list order).
    /// Otherwise — or when nothing matches — the template with `defaultId`,
    /// then the built-in General, then the first template.
    static func select(
        from templates: [SummaryTemplate],
        titles: [String],
        defaultId: String?,
        autoPick: Bool
    ) -> SummaryTemplate? {
        guard !templates.isEmpty else { return nil }
        if autoPick, let matched = bestMatch(in: templates, titles: titles) {
            return matched
        }
        if let defaultId, let t = templates.first(where: { $0.id == defaultId }) {
            return t
        }
        if let general = templates.first(where: { $0.id == BuiltInTemplates.defaultTemplateId }) {
            return general
        }
        return templates.first
    }

    /// The keyword-matched template, or nil when no keyword appears in any title.
    static func bestMatch(in templates: [SummaryTemplate], titles: [String]) -> SummaryTemplate? {
        let haystacks = titles.map(normalize).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !haystacks.isEmpty else { return nil }

        var best: (template: SummaryTemplate, hits: Int, longest: Int)?
        for template in templates {
            var hits = 0
            var longest = 0
            for keyword in template.matchKeywords {
                let needle = normalize(keyword)
                guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if haystacks.contains(where: { $0.contains(needle) }) {
                    hits += 1
                    longest = max(longest, needle.count)
                }
            }
            guard hits > 0 else { continue }
            if let current = best {
                if hits > current.hits || (hits == current.hits && longest > current.longest) {
                    best = (template, hits, longest)
                }
            } else {
                best = (template, hits, longest)
            }
        }
        return best?.template
    }

    /// Lowercases, turns everything except letters/digits into single spaces
    /// and pads with spaces, so `contains(" kw ")` is a whole-word match
    /// ("daily" ≠ "dailymotion"). Joiners `:` `/` `&` survive only *between*
    /// two letters/digits, so "1:1" and "r&d" stay one token while
    /// "Interview: Sam" still yields the word "interview".
    static func normalize(_ text: String) -> String {
        let alnum = CharacterSet.alphanumerics
        let joiners = CharacterSet(charactersIn: ":/&")
        let scalars = Array(text.lowercased().unicodeScalars)
        var out = " "
        var lastWasSpace = true
        for (index, scalar) in scalars.enumerated() {
            var keep = alnum.contains(scalar)
            if !keep, joiners.contains(scalar), index > 0, index + 1 < scalars.count {
                keep = alnum.contains(scalars[index - 1]) && alnum.contains(scalars[index + 1])
            }
            if keep {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if !lastWasSpace { out.append(" ") }
        return out
    }
}
