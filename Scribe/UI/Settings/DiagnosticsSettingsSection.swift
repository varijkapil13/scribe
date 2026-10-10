import AppKit
import SwiftUI

/// Settings › About › Diagnostics: the MetricKit payloads Scribe kept on this
/// Mac (see `ScribeMetricKitCollector`). Reveal, export or delete them —
/// nothing is ever sent anywhere.
struct DiagnosticsSettingsSection: View {

    @State private var files: [ScribeDiagnosticsFile] = []

    private let store = ScribeDiagnosticsStore.live()

    var body: some View {
        Section {
            LabeledContent("Saved reports", value: summary)
            HStack {
                Button("Reveal in Finder") { reveal() }
                Button("Export…") { export() }
                    .disabled(files.isEmpty)
                Spacer()
                Button("Delete All", role: .destructive) {
                    store.removeAll()
                    reload()
                }
                .disabled(files.isEmpty)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("macOS reports crashes, hangs and performance data to Scribe through MetricKit. Scribe keeps the last \(ScribeDiagnosticsRotation.maxFiles) reports on this Mac and never sends them anywhere — export them if you want to attach them to a bug report.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { reload() }
    }

    private var summary: String {
        let diagnostics = files.filter { $0.kind == .diagnostic }.count
        let metrics = files.count - diagnostics
        if files.isEmpty { return "None" }
        return "\(diagnostics) diagnostic, \(metrics) metric"
    }

    private func reload() {
        files = store.files()
    }

    private func reveal() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported diagnostics."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try store.export(into: parent, date: Date())
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't export diagnostics"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
