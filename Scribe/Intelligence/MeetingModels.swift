import Foundation

// MARK: - Meeting intelligence data models
//
// Pure value types (Foundation only) extracted from `MeetingSummarizer.swift`
// so they can be shared with the iOS target, which does NOT compile the
// summarizer (FoundationModels is device-gated / iOS-26+ and lives on the
// macOS recording path). `TranscriptStore` persists these, so they must be
// portable independently of the generator that produces them.

/// A structured meeting summary produced by on-device Apple Intelligence.
///
/// Contains an executive summary, key decisions, action items, topics, and
/// follow-up questions extracted from a meeting transcript.
struct MeetingSummary: Codable, Equatable, Identifiable {

    /// Unique identifier for this summary.
    let id: UUID
    /// The session that was summarized.
    let sessionId: String
    /// A 2-4 paragraph executive summary of the meeting.
    let summary: String
    /// Key decisions made during the meeting.
    let keyDecisions: [String]
    /// Action items extracted from the transcript.
    let actionItems: [ActionItem]
    /// Main topics discussed in the meeting.
    let keyTopics: [String]
    /// Open questions that need follow-up.
    let followUpQuestions: [String]
    /// When this summary was generated.
    let createdAt: Date
}

/// An action item extracted from a meeting transcript.
///
/// Each action item includes the original transcript text that led to its
/// extraction, making it easy to verify and provide context.
struct ActionItem: Codable, Equatable, Identifiable, Hashable {

    /// Unique identifier for this action item.
    let id: UUID
    /// What needs to be done.
    let description: String
    /// Who should do it, if mentioned in the transcript.
    let assignee: String?
    /// When it is due, if mentioned in the transcript.
    let deadline: String?
    /// Inferred priority based on language cues and context.
    let priority: Priority?
    /// The original transcript text that led to this action item.
    let sourceText: String

    /// Priority level for an action item.
    enum Priority: String, Codable, CaseIterable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
    }
}
