import Foundation
import FoundationModels

/// Suggests real names for diarized "Speaker N" labels with the on-device
/// model, using the calendar attendees (when the recording matched an event)
/// and conversational cues ("Thanks, Priya — over to you").
///
/// Guarded hard: a suggestion is applied only if the name is one of the
/// attendees or literally appears in the transcript, each name is used once,
/// and a speaker the user already named is never touched. Anything else is
/// dropped, so a confused model can't invent people.
enum SpeakerNameSuggester {

    /// Character budget for transcript lines in the prompt (small on-device
    /// context window).
    static let transcriptBudget = 5_000

    @MainActor
    static func applySuggestions(sessionId: String, store: TranscriptStore) async {
        guard case .available = SystemLanguageModel.default.availability else { return }
        do {
            let session = try store.fetchSession(id: sessionId)
            let segments = try store.fetchSegments(sessionId: sessionId)
            let existing = try store.fetchSpeakerNames(sessionId: sessionId)
            let you = SpeakerNamePreferences.defaultYouName().lowercased()
            let attendees = (session?.attendees ?? [])
                .map(\.displayName)
                .filter { !$0.isEmpty && $0.lowercased() != you }

            let lines = segments.map { (SpeakerNameResolver.effectiveKey(for: $0), $0.text) }
            let keys = Set(lines.map { $0.0 }).filter { $0.hasPrefix("Speaker ") && existing[$0] == nil }
            guard !keys.isEmpty else { return }

            let prompt = buildPrompt(lines: lines, speakerKeys: keys.sorted(), attendees: attendees)
            let model = LanguageModelSession(instructions: instructions)
            let response = try await model.respond(to: prompt).content

            let transcriptText = segments.map(\.text).joined(separator: " ")
            let names = parse(response, speakerKeys: keys, attendees: attendees, transcriptText: transcriptText)
            for (key, name) in names {
                try store.setSpeakerName(name, forKey: key, sessionId: sessionId)
            }
        } catch {
            Log.speech.error("Speaker name suggestion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let instructions = """
    You identify which named person is speaking in a meeting transcript. \
    Only use names that appear in the attendee list or are clearly used to \
    address or introduce a speaker in the transcript. If unsure, answer null. \
    Reply with JSON only: an object mapping each speaker label to a name or null.
    """

    /// Prompt with the attendees and the transcript (latest lines dropped
    /// first when over budget — introductions usually happen early).
    static func buildPrompt(lines: [(String, String)], speakerKeys: [String], attendees: [String]) -> String {
        var transcript = ""
        for (key, text) in lines {
            let line = "\(key): \(text)\n"
            if transcript.count + line.count > transcriptBudget { break }
            transcript += line
        }
        let attendeeText = attendees.isEmpty ? "(none)" : attendees.joined(separator: ", ")
        return """
        Attendees: \(attendeeText)
        Speaker labels to identify: \(speakerKeys.joined(separator: ", "))

        Transcript:
        \(transcript)
        Answer with JSON like {"Speaker 1": "Name", "Speaker 2": null}.
        """
    }

    /// Parses and validates the model's JSON. Keeps only known speaker keys,
    /// names that are attendees or appear in the transcript, and each name
    /// at most once (first key wins).
    static func parse(
        _ response: String,
        speakerKeys: Set<String>,
        attendees: [String],
        transcriptText: String
    ) -> [String: String] {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        let attendeeLookup = Dictionary(
            attendees.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }
        )
        let haystack = " " + transcriptText.lowercased() + " "
        var used = Set<String>()
        var result: [String: String] = [:]
        for key in object.keys.sorted() where speakerKeys.contains(key) {
            guard let raw = object[key] as? String else { continue }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !used.contains(name.lowercased()) else { continue }

            let canonical: String
            if let attendee = attendeeLookup[name.lowercased()] {
                canonical = attendee
            } else if appearsAsWord(name.lowercased(), in: haystack) {
                canonical = name
            } else {
                continue
            }
            used.insert(canonical.lowercased())
            result[key] = canonical
        }
        return result
    }

    private static func appearsAsWord(_ word: String, in haystack: String) -> Bool {
        let boundaries = CharacterSet.alphanumerics.inverted
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: word, range: searchRange) {
            let before = found.lowerBound > haystack.startIndex ? haystack[haystack.index(before: found.lowerBound)] : " "
            let after = found.upperBound < haystack.endIndex ? haystack[found.upperBound] : " "
            if before.unicodeScalars.allSatisfy(boundaries.contains),
               after.unicodeScalars.allSatisfy(boundaries.contains) {
                return true
            }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }
}
