import AppIntents
import Foundation

/// A recorded meeting (a transcript session) as Shortcuts / Siri see it.
struct MeetingEntity: AppEntity, Sendable {

    let id: String
    let title: String
    let startedAt: Date
    let durationSeconds: Int?

    init(id: String, title: String, startedAt: Date, durationSeconds: Int?) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }

    init(session: Session) {
        self.init(
            id: session.id,
            title: ScribeIntentsText.displayTitle(session.title, fallback: "Meeting"),
            startedAt: session.createdAt,
            durationSeconds: session.durationSeconds
        )
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Meeting")
    }

    static var defaultQuery: MeetingEntityQuery { MeetingEntityQuery() }

    var displayRepresentation: DisplayRepresentation {
        var subtitle = startedAt.formatted(date: .abbreviated, time: .shortened)
        if let durationSeconds, durationSeconds >= 60 {
            subtitle += " · \(durationSeconds / 60) min"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: DisplayRepresentation.Image(systemName: "waveform")
        )
    }
}

/// Resolves meetings by id, by text (title / calendar event / attendees) and
/// suggests the most recent ones.
struct MeetingEntityQuery: EntityStringQuery {

    init() {}

    func entities(for identifiers: [MeetingEntity.ID]) async throws -> [MeetingEntity] {
        try ScribeIntentsData.live.sessions(ids: identifiers).map(MeetingEntity.init(session:))
    }

    func entities(matching string: String) async throws -> [MeetingEntity] {
        try ScribeIntentsData.live.sessions(matching: string).map(MeetingEntity.init(session:))
    }

    func suggestedEntities() async throws -> [MeetingEntity] {
        try ScribeIntentsData.live.recentSessions().map(MeetingEntity.init(session:))
    }
}
