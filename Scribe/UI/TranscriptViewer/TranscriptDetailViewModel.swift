import Foundation
import Combine
import AppKit

/// ViewModel that loads and manages data for a single transcript session.
///
/// `@MainActor` matches the rest of the UI layer and allows published property
/// updates to happen without explicit actor hops from async contexts.
@MainActor
final class TranscriptDetailViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var session: Session
    @Published var segments: [Segment] = []
    @Published var meetingSummary: MeetingSummary?
    @Published var transcriptAnalysis: TranscriptAnalysis?
    @Published var isGeneratingSummary: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var completedActionItems: Set<UUID> = []
    /// Action item ids whose conversion already produced a `TodoTask`. Used by
    /// the row's "Convert to task" button to switch to "Open task" once a
    /// link exists.
    @Published var convertedActionItems: Set<UUID> = []
    @Published var summaryError: String?
    @Published var analysisError: String?

    /// Whether on-device Apple Intelligence is usable right now. Read once on
    /// appear (and re-checked when a generation throws `notAvailable`) so the
    /// reader can show a calm "unavailable on this Mac" state *before* the user
    /// taps Generate, instead of only surfacing it as a post-tap error.
    @Published var intelligenceAvailability: AppleIntelligenceAvailability = .available

    /// Monotonic counters bumped whenever fresh AI content lands. Views observe
    /// these to drive a reduce-motion-gated reveal of the generated text.
    @Published private(set) var summaryRevealToken: Int = 0
    @Published private(set) var analysisRevealToken: Int = 0

    // MARK: - Selection State (for moving segments)

    @Published var isSelecting: Bool = false
    @Published var selectedSegmentIds: Set<Int64> = []
    @Published var moveTargetCandidates: [Session] = []

    // MARK: - Properties

    private let store: TranscriptStore
    private let taskStore: TaskStore

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

    init(session: Session,
         store: TranscriptStore = TranscriptStore(),
         taskStore: TaskStore = TaskStore()) {
        self.session = session
        self.store = store
        self.taskStore = taskStore
    }

    /// Re-fetches session metadata from the store. Called after edits to keep
    /// the view in sync.
    func reloadSession() {
        if let fresh = try? store.fetchSession(id: session.id) {
            session = fresh
        }
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
        do {
            try store.updateSession(updated)
            session = updated
            NotificationCenter.default.post(name: .scribeSessionUpdated, object: updated.id)
        } catch {
            Log.storage.error("Failed to update session title: \(error.localizedDescription)")
        }
    }

    /// Updates the session tags in the store.
    func updateSessionTags(_ tags: [String]) {
        var updated = session
        updated.tags = tags
        do {
            try store.updateSession(updated)
            session = updated
            NotificationCenter.default.post(name: .scribeSessionUpdated, object: updated.id)
        } catch {
            Log.storage.error("Failed to update session tags: \(error.localizedDescription)")
        }
    }

    // MARK: - Intelligence Methods

    /// Loads a previously generated summary from the store and hydrates the
    /// completion state of its action items.
    func loadSummary() {
        meetingSummary = try? store.fetchSummary(sessionId: session.id)
        completedActionItems = (try? store.fetchCompletedActionItemIds(sessionId: session.id)) ?? []
        refreshConvertedActionItems()
    }

    /// Refreshes the cache of action-item ids that already have a linked
    /// task. Called after the summary loads and after a fresh conversion so
    /// the row's button can flip to "Open task".
    func refreshConvertedActionItems() {
        guard let summary = meetingSummary else {
            convertedActionItems = []
            return
        }
        let ids = summary.actionItems.map { $0.id.uuidString }
        let linked = (try? taskStore.actionItemIdsWithLinkedTasks(in: ids)) ?? []
        convertedActionItems = Set(
            summary.actionItems
                .filter { linked.contains($0.id.uuidString) }
                .map(\.id)
        )
    }

    /// Converts a single action item into a `TodoTask`. Returns the new task
    /// (or the existing one when the row had already been converted) so the
    /// caller can immediately open the editor sheet on it.
    @discardableResult
    func convertActionItemToTask(_ item: ActionItem) -> TodoTask? {
        let actionItemId = item.id.uuidString
        if let existing = try? taskStore.fetchTaskForActionItem(actionItemId) {
            return existing
        }
        let draft = ActionItemConverter.draft(from: item, sessionId: session.id)
        do {
            let created = try taskStore.createTask(
                title: draft.title,
                notes: draft.notes,
                projectId: draft.projectId,
                priority: draft.priority,
                dueAt: draft.dueAt,
                sourceSessionId: draft.sourceSessionId,
                sourceActionItemId: draft.sourceActionItemId,
                tags: draft.tags
            )
            convertedActionItems.insert(item.id)
            return created
        } catch {
            Log.storage.error("convertActionItemToTask failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generates an AI-powered meeting summary using on-device Apple Intelligence.
    @MainActor
    func generateSummary() async {
        Log.intelligence.info("generateSummary tapped — \(self.segments.count) segments")
        guard !segments.isEmpty else {
            summaryError = "Transcript is empty — record or move segments back before summarising."
            Log.intelligence.error("generateSummary aborted — no segments")
            return
        }

        isGeneratingSummary = true
        summaryError = nil
        defer { isGeneratingSummary = false }
        announce("Generating summary with Apple Intelligence")

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
            summaryRevealToken &+= 1
            Log.intelligence.info("generateSummary succeeded — \(summary.actionItems.count) action items")
            announce("Summary ready. \(summary.actionItems.count) action item\(summary.actionItems.count == 1 ? "" : "s") found.")
        } catch {
            summaryError = error.localizedDescription
            refreshIntelligenceAvailability()
            Log.intelligence.error("generateSummary failed: \(error.localizedDescription)")
            announce("Summary generation failed.")
        }
    }

    /// Re-queries Apple Intelligence availability and stores it for the UI. Cheap
    /// enough to call on appear and after any generation that throws.
    func refreshIntelligenceAvailability() {
        intelligenceAvailability = AppleIntelligenceAvailability.current
    }

    /// Posts a VoiceOver announcement for generation lifecycle moments. No-op
    /// for sighted users; routed through AppKit's accessibility notification so
    /// it doesn't depend on a particular view being focused.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// Runs NaturalLanguage analysis (entities, sentiment, topics, language detection)
    /// on the transcript segments.
    func runAnalysis() {
        guard !segments.isEmpty else {
            analysisError = "Transcript is empty — record or move segments back before analysing."
            return
        }
        isAnalyzing = true
        analysisError = nil
        announce("Analyzing transcript")
        let capturedSegments = segments
        let sessionId = session.id
        Task {
            let analysis = await Task.detached(priority: .userInitiated) {
                TranscriptAnalyzer.analyzeTranscript(segments: capturedSegments)
            }.value

            try? store.saveEntities(analysis.entities, sessionId: sessionId)
            transcriptAnalysis = analysis
            analysisRevealToken &+= 1
            isAnalyzing = false
            announce("Analysis ready.")
        }
    }

    /// Loads cached analysis results. If cached entities exist and no
    /// in-memory analysis is present yet, triggers a full re-analysis so the
    /// remaining fields (sentiment, topics, etc.) are populated.
    func loadAnalysis() {
        // Don't re-run analysis if we already have results in memory.
        guard transcriptAnalysis == nil else { return }
        let entities = (try? store.fetchEntities(sessionId: session.id)) ?? []
        if !entities.isEmpty {
            // We have cached entities; run a quick re-analysis for the rest.
            runAnalysis()
        }
    }

    // MARK: - Segment Selection / Move

    /// Toggles selection mode. Exiting selection mode clears the selection.
    func toggleSelectMode() {
        isSelecting.toggle()
        if !isSelecting {
            selectedSegmentIds.removeAll()
        }
    }

    /// Toggles a segment's membership in the current selection.
    func toggleSegmentSelection(_ id: Int64) {
        if selectedSegmentIds.contains(id) {
            selectedSegmentIds.remove(id)
        } else {
            selectedSegmentIds.insert(id)
        }
    }

    /// Loads the list of sessions the current selection can be moved into
    /// (everything except the current session, ordered most-recent first).
    func loadMoveTargets() {
        let all = (try? store.fetchAllSessions()) ?? []
        moveTargetCandidates = all.filter { $0.id != session.id }
    }

    /// Moves the currently selected segments into `target`. On success, exits
    /// selection mode, reloads segments, and notifies the sidebar so both
    /// sessions reflect new durations.
    func moveSelectedSegments(to target: Session) {
        let ids = Array(selectedSegmentIds)
        guard !ids.isEmpty else { return }
        do {
            try store.moveSegments(ids: ids, toSessionId: target.id)
            selectedSegmentIds.removeAll()
            isSelecting = false
            loadSegments()
            reloadSession()
            NotificationCenter.default.post(name: .scribeSessionUpdated, object: session.id)
            NotificationCenter.default.post(name: .scribeSessionUpdated, object: target.id)
        } catch {
            Log.storage.error("Failed to move segments: \(error.localizedDescription)")
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
