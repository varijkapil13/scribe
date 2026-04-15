import Foundation

/// Exports a transcript session as a JSON document using dedicated Codable
/// structs that match the PRD-specified schema.
struct JSONExporter {

    // MARK: - Export-Only Codable Types

    /// Top-level wrapper for the exported JSON.
    private struct ExportDocument: Codable {
        let session: ExportSession
        let segments: [ExportSegment]
    }

    /// Session metadata in the exported JSON.
    private struct ExportSession: Codable {
        let id: String
        let title: String
        let createdAt: String
        let durationS: Int
        let language: String

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdAt = "created_at"
            case durationS = "duration_s"
            case language
        }
    }

    /// A single transcript segment in the exported JSON.
    private struct ExportSegment: Codable {
        let startMs: Int
        let endMs: Int
        let speaker: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
            case speaker
            case text
        }
    }

    // MARK: - Public

    static func export(session: Session, segments: [Segment]) -> String {
        let exportSession = ExportSession(
            id: session.id,
            title: session.title,
            createdAt: iso8601String(from: session.createdAt),
            durationS: session.durationSeconds ?? 0,
            language: session.language ?? "en"
        )

        let exportSegments = segments.map { segment in
            ExportSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: segment.speaker,
                text: segment.text
            )
        }

        let document = ExportDocument(session: exportSession, segments: exportSegments)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(document),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return jsonString + "\n"
    }

    // MARK: - Private Helpers

    /// Returns an ISO 8601 formatted string for the given date.
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
