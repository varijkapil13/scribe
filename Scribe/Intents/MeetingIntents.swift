import AppIntents
import Foundation

/// Picks the meeting an intent works on: the one given, else the newest
/// finished recording.
enum MeetingIntentTarget {
    static func sessionId(for meeting: MeetingEntity?, data: ScribeIntentsData) throws -> String {
        if let meeting {
            guard try !data.sessions(ids: [meeting.id]).isEmpty else { throw ScribeIntentError.meetingNotFound }
            return meeting.id
        }
        guard let latest = try data.latestFinishedSession() else { throw ScribeIntentError.noMeetings }
        return latest.id
    }
}

/// Returns a meeting's summary as text (the latest meeting when none is given).
struct GetMeetingSummaryIntent: AppIntent {

    static var title: LocalizedStringResource { "Get Meeting Summary" }

    @Parameter(title: "Meeting")
    var meeting: MeetingEntity?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = ScribeIntentsData.live
        let sessionId = try MeetingIntentTarget.sessionId(for: meeting, data: data)
        guard let text = try data.summaryText(sessionId: sessionId) else { throw ScribeIntentError.noSummary }
        return .result(value: text, dialog: "\(text)")
    }
}

/// Returns a meeting's transcript as text (the latest meeting when none is
/// given).
struct GetMeetingTranscriptIntent: AppIntent {

    static var title: LocalizedStringResource { "Get Meeting Transcript" }

    @Parameter(title: "Meeting")
    var meeting: MeetingEntity?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = ScribeIntentsData.live
        let sessionId = try MeetingIntentTarget.sessionId(for: meeting, data: data)
        guard let text = try data.transcriptText(sessionId: sessionId) else { throw ScribeIntentError.noTranscript }
        return .result(value: text)
    }
}
