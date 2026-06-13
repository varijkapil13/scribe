import Foundation
import AppKit

/// Supported export formats for transcript data.
enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case plainText = "Plain Text"
    case json = "JSON"

    var id: String { rawValue }

    /// The file extension used when saving to disk.
    var fileExtension: String {
        switch self {
        case .markdown:  return "md"
        case .plainText: return "txt"
        case .json:      return "json"
        }
    }
}

/// Coordinates transcript export across the supported formats.
struct ExportManager {

    /// Exports a session and its segments in the requested format, returning the
    /// formatted string.
    static func export(session: Session, segments: [Segment], format: ExportFormat) -> String {
        switch format {
        case .markdown:
            return exportToMarkdown(session: session, segments: segments)
        case .plainText:
            return exportToPlainText(session: session, segments: segments)
        case .json:
            return exportToJSON(session: session, segments: segments)
        }
    }

    /// Returns a Markdown-formatted transcript.
    static func exportToMarkdown(session: Session, segments: [Segment]) -> String {
        MarkdownExporter.export(session: session, segments: segments)
    }

    /// Returns a plain-text transcript.
    static func exportToPlainText(session: Session, segments: [Segment]) -> String {
        PlainTextExporter.export(session: session, segments: segments)
    }

    /// Returns a JSON-encoded transcript.
    static func exportToJSON(session: Session, segments: [Segment]) -> String {
        JSONExporter.export(session: session, segments: segments)
    }

    /// Presents an NSSavePanel so the user can choose where to save the exported
    /// content, then writes the file. Must be called on the main actor because
    /// NSSavePanel is main-actor-isolated.
    @MainActor
    static func saveToFile(content: String, defaultName: String, fileExtension: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(fileExtension)"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Don't let a failed write look like a successful export. Tell the
            // user why (disk full / permission denied / read-only volume) so the
            // sheet closing isn't mistaken for "saved".
            NSLog("ExportManager: failed to write file – \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = "Scribe couldn't save the file to \(url.lastPathComponent).\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
