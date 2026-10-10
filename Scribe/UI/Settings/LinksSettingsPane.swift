import SwiftUI

/// Settings → Links & Handoff: `scribe://` automation links and Handoff.
struct LinksSettingsPane: View {
    @AppStorage(EntryPointSettings.allowCaptureLinksKey) private var allowCaptureLinks = true
    @AppStorage(EntryPointSettings.handoffEnabledKey) private var handoffEnabled = true

    private struct LinkExample: Identifiable {
        let link: String
        let summary: String
        var id: String { link }
    }

    private static let examples: [LinkExample] = [
        LinkExample(link: "scribe://new-note?title=Idea&body=…", summary: "Create a note"),
        LinkExample(link: "scribe://new-task?title=Call%20Sam&due=tomorrow", summary: "Create a task"),
        LinkExample(link: "scribe://note/<id>", summary: "Open a note (Copy Link on any note)"),
        LinkExample(link: "scribe://search?q=roadmap", summary: "Search"),
        LinkExample(link: "scribe://today", summary: "Go to Today"),
        LinkExample(link: "scribe://record/start", summary: "Start recording"),
        LinkExample(link: "scribe://dictate", summary: "Start or stop dictation"),
    ]

    var body: some View {
        Form {
            Section("Links") {
                Toggle("Allow links to start and stop recording and dictation", isOn: $allowCaptureLinks)
                Text("Other apps, scripts and Shortcuts can control Scribe with scribe:// links. When this is off, recording and dictation links are ignored; links that open or create notes and tasks still work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Examples") {
                ForEach(Self.examples) { example in
                    LabeledContent {
                        Text(example.summary)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(example.link)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Handoff") {
                Toggle("Offer the open note or task to Handoff and search", isOn: $handoffEnabled)
                Text("Your other devices can pick up where you left off, and recently viewed notes and tasks can be suggested by system search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
