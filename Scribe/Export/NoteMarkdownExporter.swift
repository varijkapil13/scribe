import Foundation

/// Exports a Note as a markdown document. When the note has linked recording
/// sessions, appends a "## Linked recordings" tail with each session's
/// summary, action items, and entities/topics — so an exported note carries
/// its transcript context with it.
struct NoteMarkdownExporter {

    /// Exports the note's title, body, and (when present) linked-recordings
    /// tail. Takes the stores as parameters so tests can inject in-memory
    /// instances.
    static func export(
        note: Note,
        transcriptStore: TranscriptStore = .shared
    ) -> String {
        var lines: [String] = []

        // Title
        let title = note.title.isEmpty ? "Untitled note" : note.title
        lines.append("# \(title)")
        lines.append("")
        lines.append("**Last edited:** \(formatDate(note.updatedAt))")
        lines.append("")

        // Freeform body (may be empty)
        if !note.body.isEmpty {
            lines.append(note.body)
            lines.append("")
        }

        // Linked recordings tail
        let sessions = (try? transcriptStore.fetchSessions(forNoteId: note.id)) ?? []
        if !sessions.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## Linked recordings")
            lines.append("")
            for session in sessions {
                appendSessionBlock(session: session,
                                   transcriptStore: transcriptStore,
                                   into: &lines)
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Per-session block

    private static func appendSessionBlock(
        session: Session,
        transcriptStore: TranscriptStore,
        into lines: inout [String]
    ) {
        let sessionTitle = session.title.isEmpty ? "Untitled session" : session.title
        lines.append("### \(sessionTitle) — \(formatDate(session.createdAt))")
        lines.append("")
        if let secs = session.durationSeconds, secs > 0 {
            lines.append("**Duration:** \(formatDuration(secs))")
            lines.append("")
        }

        // Summary
        if let summary = try? transcriptStore.fetchSummary(sessionId: session.id) {
            lines.append("**Summary**")
            lines.append("")
            lines.append(summary.summary)
            lines.append("")

            if !summary.keyDecisions.isEmpty {
                lines.append("**Key decisions**")
                for decision in summary.keyDecisions {
                    lines.append("- \(decision)")
                }
                lines.append("")
            }

            if !summary.actionItems.isEmpty {
                lines.append("**Action items**")
                let completedIds = (try? transcriptStore
                    .fetchCompletedActionItemIds(sessionId: session.id)) ?? []
                for item in summary.actionItems {
                    let checkbox = completedIds.contains(item.id) ? "[x]" : "[ ]"
                    var line = "- \(checkbox) \(item.description)"
                    if let assignee = item.assignee, !assignee.isEmpty {
                        line += " — _\(assignee)_"
                    }
                    if let deadline = item.deadline, !deadline.isEmpty {
                        line += " (due \(deadline))"
                    }
                    lines.append(line)
                }
                lines.append("")
            }

            if !summary.keyTopics.isEmpty {
                lines.append("**Topics**")
                for topic in summary.keyTopics {
                    lines.append("- \(topic)")
                }
                lines.append("")
            }
        }

        // Entities
        let entities = (try? transcriptStore.fetchEntities(sessionId: session.id)) ?? []
        if !entities.isEmpty {
            lines.append("**Mentioned**")
            let grouped = Dictionary(grouping: entities, by: { $0.type })
            // Stable ordering: person → organization → place → date
            for entityType in ExtractedEntity.EntityType.allCases {
                guard let items = grouped[entityType], !items.isEmpty else { continue }
                let names = items.map(\.text).joined(separator: ", ")
                lines.append("- \(displayLabel(for: entityType)): \(names)")
            }
            lines.append("")
        }
    }

    // MARK: - Helpers

    private static func displayLabel(for type: ExtractedEntity.EntityType) -> String {
        switch type {
        case .person:       return "People"
        case .organization: return "Organizations"
        case .place:        return "Places"
        case .date:         return "Dates"
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}
