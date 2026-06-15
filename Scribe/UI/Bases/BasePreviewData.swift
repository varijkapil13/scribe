import Foundation

/// Sample ``BaseRecord`` fixtures used by the Bases view `#Preview`s so each
/// view renders without a live store. Not referenced by production code.
enum BasePreviewData {

    static let records: [BaseRecord] = [
        record(
            title: "Design review notes",
            excerpt: "Walked through the new properties pane and the table layout.",
            properties: [
                NoteProperty(key: "status", value: .select("In Progress")),
                NoteProperty(key: "priority", value: .number(1)),
                NoteProperty(key: "due", value: .date(date("2026-06-20"))),
                NoteProperty(key: "starred", value: .checkbox(true)),
            ]
        ),
        record(
            title: "Q3 planning",
            excerpt: "Roadmap items and rough sizing for the next quarter.",
            properties: [
                NoteProperty(key: "status", value: .select("Todo")),
                NoteProperty(key: "priority", value: .number(3)),
                NoteProperty(key: "due", value: .date(date("2026-07-01"))),
                NoteProperty(key: "starred", value: .checkbox(false)),
            ]
        ),
        record(
            title: "Bases shipping checklist",
            excerpt: "Tests green, sidebar entry wired, PR opened.",
            properties: [
                NoteProperty(key: "status", value: .select("Done")),
                NoteProperty(key: "priority", value: .number(2)),
                NoteProperty(key: "due", value: .date(date("2026-06-15"))),
                NoteProperty(key: "starred", value: .checkbox(true)),
            ]
        ),
    ]

    private static func record(title: String, excerpt: String, properties: [NoteProperty]) -> BaseRecord {
        var note = Note(title: title, body: excerpt)
        note.bodyExcerpt = excerpt
        return BaseRecord(note: note, properties: properties)
    }

    private static func date(_ s: String) -> Date {
        PropertyCodec.dateFormatter.date(from: s) ?? Date()
    }
}
