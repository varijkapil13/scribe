import FluidAudio
import Foundation

/// Runs FluidAudio's offline diarizer (pyannote segmentation + WeSpeaker
/// embeddings + VBx clustering, all Core ML) over one audio file and returns
/// the speaker turns in seconds from the start of that file.
///
/// Shared by the Mac (`SpeakerDiarizationRunner`) and the iPhone / iPad app
/// (`IOSDiarizationScheduler`). Everything is local to the call, so the
/// non-Sendable diarizer never crosses an isolation boundary; call it off the
/// main actor (e.g. from `Task.detached`).
enum FluidDiarizationEngine {

    /// - Parameters:
    ///   - modelsRoot: The folder holding `speaker-diarization-coreml/`
    ///     (bundled or downloaded), or nil for FluidAudio's own cache.
    ///   - allowNetwork: False keeps FluidAudio from downloading anything
    ///     (the models must already be in `modelsRoot`).
    nonisolated static func turns(
        forAudioAt url: URL,
        modelsRoot: URL?,
        allowNetwork: Bool
    ) async throws -> [DiarizedSegmentRebuilder.Turn] {
        ModelHub.offlineMode = !allowNetwork
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: modelsRoot)
        let result = try await manager.process(url)
        return result.segments.map { segment in
            DiarizedSegmentRebuilder.Turn(
                speakerId: segment.speakerId,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)
            )
        }
    }
}

extension Notification.Name {
    /// Posted (object: session id) when diarization or name suggestions
    /// changed a session's speakers, so open transcript views reload names.
    static let scribeSpeakersDidChange = Notification.Name("scribe.speakersDidChange")
}
