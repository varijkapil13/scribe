// Scribe/Intelligence/Translation/ScribeTranslationRunner.swift
import Foundation
import SwiftUI
import Translation

/// The only place Scribe talks to Apple's Translation framework.
///
/// A `TranslationSession` can't be created freely on every OS version — the
/// supported way is the `.translationTask(_:action:)` view modifier, which
/// hands the action a session (and shows the system's language-download UI
/// when needed). ``ScribeTranslationHost`` wraps that modifier; the session never
/// leaves the action closure, which runs off the main actor and only passes
/// plain strings back.
enum ScribeTranslationRunner {

    /// Strings per request batch (progress granularity).
    static let batchSize = 40

    /// Languages the system can translate into, sorted by display name.
    static func supportedLanguages() async -> [Locale.Language] {
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        return languages.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    /// "German", "Portuguese (Brazil)", … in the user's locale.
    nonisolated static func displayName(for language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Translates `texts` with `session`, in batches, reporting progress
    /// (0…1). Returns one translation per input, in order (an input the
    /// framework skipped keeps its original text).
    nonisolated static func translate(_ texts: [String],
                                      using session: TranslationSession,
                                      progress: @Sendable (Double) async -> Void) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        var output = texts
        var done = 0
        let indexed = Array(texts.enumerated())
        for batch in ScribeTranslationOutput.batches(indexed, size: batchSize) {
            try Task.checkCancellation()
            let requests = batch.map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id), index < output.count {
                    output[index] = response.targetText
                }
            }
            done += batch.count
            await progress(Double(done) / Double(texts.count))
        }
        return output
    }
}

/// What one translation run produced.
enum ScribeTranslationOutcome: Sendable {
    case finished([String])
    case failed(String)
}

/// Runs a translation of `texts` whenever `configuration` is set (or
/// invalidated) and reports the result on the main actor.
struct ScribeTranslationHost: ViewModifier {
    let configuration: TranslationSession.Configuration?
    let texts: [String]
    let onProgress: @MainActor @Sendable (Double) -> Void
    let onFinish: @MainActor @Sendable (ScribeTranslationOutcome) -> Void

    func body(content: Content) -> some View {
        let texts = self.texts
        let onProgress = self.onProgress
        let onFinish = self.onFinish
        // The action is written as an explicitly `@Sendable` (so nonisolated)
        // closure: the session stays in this closure's own isolation domain
        // whatever isolation the SDK gives the parameter. If CI complains
        // about this modifier, this is the line to adjust.
        return content.translationTask(configuration) { @Sendable session in
            let outcome: ScribeTranslationOutcome
            do {
                let translated = try await ScribeTranslationRunner.translate(texts, using: session) { fraction in
                    await onProgress(fraction)
                }
                outcome = .finished(translated)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await onFinish(outcome)
        }
    }
}
