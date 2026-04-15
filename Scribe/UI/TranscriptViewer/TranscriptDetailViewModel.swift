import Foundation
import Combine

/// ViewModel that loads and manages data for a single transcript session.
final class TranscriptDetailViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var segments: [Segment] = []

    // MARK: - Properties

    let session: Session
    private let store: TranscriptStore

    // MARK: - Computed Properties

    /// Human-readable duration formatted as "Xh Ym Zs" or "Ym Zs".
    var formattedDuration: String {
        guard let total = session.durationSeconds else {
            return "--:--"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    // MARK: - Initializer

    init(session: Session, store: TranscriptStore = TranscriptStore()) {
        self.session = session
        self.store = store
    }

    // MARK: - Public Methods

    /// Fetches all segments for the session from the store.
    func loadSegments() {
        do {
            segments = try store.fetchSegments(sessionId: session.id)
        } catch {
            segments = []
        }
    }

    /// Updates the session title in the store.
    func updateSessionTitle(_ title: String) {
        var updated = session
        updated.title = title
        try? store.updateSession(updated)
    }

    /// Updates the session tags in the store.
    func updateSessionTags(_ tags: [String]) {
        var updated = session
        updated.tags = tags
        try? store.updateSession(updated)
    }
}
