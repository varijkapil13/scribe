import Foundation
import Combine

/// ViewModel that loads and manages data for a single transcript session.
final class TranscriptDetailViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var segments: [Segment] = []
    @Published var meetingSummary: MeetingSummary?
    @Published var transcriptAnalysis: TranscriptAnalysis?
    @Published var isGeneratingSummary: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var completedActionItems: Set<UUID> = []
    @Published var summaryError: String?

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

    // MARK: - Intelligence Methods

    /// Loads a previously generated summary from the store.
    func loadSummary() {
        meetingSummary = try? store.fetchSummary(sessionId: session.id)
    }

    /// Generates an AI-powered meeting summary using on-device Apple Intelligence.
    @MainActor
    func generateSummary() async {
        isGeneratingSummary = true
        summaryError = nil
        defer { isGeneratingSummary = false }

        let segmentData = segments.map {
            (speaker: $0.speaker, text: $0.text, timestamp: $0.formattedTimestamp)
        }

        do {
            let summary = try await MeetingSummarizer.summarize(
                sessionId: session.id,
                title: session.title,
                segments: segmentData
            )
            try? store.saveSummary(summary)
            meetingSummary = summary
        } catch {
            summaryError = error.localizedDescription
        }
    }

    /// Runs NaturalLanguage analysis (entities, sentiment, topics, language detection)
    /// on the transcript segments.
    func runAnalysis() {
        isAnalyzing = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let analysis = TranscriptAnalyzer.analyzeTranscript(segments: segments)
            try? store.saveEntities(analysis.entities, sessionId: session.id)
            DispatchQueue.main.async {
                self.transcriptAnalysis = analysis
                self.isAnalyzing = false
            }
        }
    }

    /// Loads cached analysis results. If cached entities exist, triggers a full
    /// re-analysis so the remaining fields (sentiment, topics, etc.) are populated.
    func loadAnalysis() {
        let entities = (try? store.fetchEntities(sessionId: session.id)) ?? []
        if !entities.isEmpty {
            // We have cached entities; run a quick re-analysis for the rest.
            runAnalysis()
        }
    }

    /// Toggles the completion state of an action item.
    func toggleActionItem(_ id: UUID) {
        if completedActionItems.contains(id) {
            completedActionItems.remove(id)
        } else {
            completedActionItems.insert(id)
        }
        try? store.toggleActionItemCompletion(id: id.uuidString)
    }
}
