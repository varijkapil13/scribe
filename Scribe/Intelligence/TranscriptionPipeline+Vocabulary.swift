import Foundation
import Speech

extension TranscriptionPipeline {

    /// Hands the user's vocabulary terms to the analyzer as contextual
    /// strings so the recognizer favours those spellings.
    ///
    /// Deliberately isolated: this is the ONLY place that touches the
    /// macOS 26 `AnalysisContext` API. If an SDK revision renames it
    /// (`contextualStrings`, `ContextualStringsTag.general`,
    /// `SpeechAnalyzer.setContext(_:)`), fix it here — the post-transcription
    /// `VocabularyCorrector` path keeps working regardless.
    ///
    /// Best effort: failures are logged, never thrown, so a context problem
    /// can't stop a recording.
    func applyContextualStrings(_ terms: [String], to analyzer: SpeechAnalyzer) async {
        guard !terms.isEmpty else { return }
        // Keep the hint list bounded; very long lists dilute the bias.
        let bounded = Array(terms.prefix(Self.maxContextualStrings))
        let context = AnalysisContext()
        context.contextualStrings[AnalysisContext.ContextualStringsTag.general] = bounded
        do {
            try await analyzer.setContext(context)
            Log.speech.info("Pipeline[\(self.speaker, privacy: .public)] applied \(bounded.count) vocabulary terms.")
        } catch {
            Log.speech.error("Pipeline[\(self.speaker, privacy: .public)] couldn't apply vocabulary: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static let maxContextualStrings = 500
}
