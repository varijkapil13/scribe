import Combine
import Foundation

/// The rolling live-transcript rows shown while recording. Kept apart from
/// `AppState` because it changes several times a second: only the views that
/// render the feed observe it.
@MainActor
final class LiveTranscript: ObservableObject {
    @Published var segments: [TranscriptionSegment] = []
}

/// Whether a recording is running and whether it is paused, without the
/// level meters and timer that `AudioSessionManager` also publishes.
@MainActor
final class RecordingStatus: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false

    func bind(isRecording: some Publisher<Bool, Never>, isPaused: some Publisher<Bool, Never>) {
        isRecording.removeDuplicates().assign(to: &$isRecording)
        isPaused.removeDuplicates().assign(to: &$isPaused)
    }
}

/// Recording elapsed time at whole-second resolution.
@MainActor
final class RecordingClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0

    func bind(duration: some Publisher<TimeInterval, Never>) {
        duration
            .map { $0.rounded(.down) }
            .removeDuplicates()
            .assign(to: &$elapsed)
    }
}
