import SwiftUI
import AppKit

/// Settings → Hooks: user scripts run after each meeting recording stops.
struct HooksSettingsPane: View {
    @AppStorage(MeetingHookSettings.enabledKey) private var enabled: Bool = false
    @State private var paths: [String] = MeetingHookSettings.hookPaths()
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("Post-meeting hooks") {
                Toggle("Run hooks when a recording stops", isOn: $enabled)
                Text("Each script runs in order after the meeting ends (and after the automatic summary, if that's on, or \(Int(MeetingHookSettings.summaryWait)) seconds at most). A script that runs longer than \(Int(MeetingHookSettings.timeout)) seconds is stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Scripts") {
                if paths.isEmpty {
                    Text("No scripts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(paths, id: \.self) { path in
                        HStack {
                            Image(systemName: FileManager.default.isExecutableFile(atPath: path)
                                  ? "terminal" : "exclamationmark.triangle.fill")
                                .foregroundStyle(FileManager.default.isExecutableFile(atPath: path)
                                                 ? Color.secondary : Color.orange)
                                .help(FileManager.default.isExecutableFile(atPath: path)
                                      ? "Executable" : "Not executable — run chmod +x on it")
                            Text(path)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Spacer()
                            Button {
                                paths.removeAll { $0 == path }
                                MeetingHookSettings.setHookPaths(paths)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \((path as NSString).lastPathComponent)")
                        }
                    }
                }
                HStack {
                    Button("Add Script…", action: chooseScripts)
                    Button(isTesting ? "Running…" : "Run on Latest Meeting", action: runTest)
                        .disabled(paths.isEmpty || isTesting)
                    Spacer()
                }
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("What a script receives") {
                Text("""
                stdin: the meeting as JSON — session_id, title, note_id, note_title, note_path, started_at, ended_at, duration_seconds, language, tags, speakers, segments (start_ms, end_ms, speaker, speaker_key, text), summary, action_items, transcript_markdown. Every key is always present.
                Environment: SCRIBE_SESSION_ID, SCRIBE_NOTE_ID, SCRIBE_NOTE_PATH, SCRIBE_EVENT.
                A non-zero exit status or a timeout shows an error banner in Scribe.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { paths = MeetingHookSettings.hookPaths() }
    }

    private func chooseScripts() {
        let panel = NSOpenPanel()
        panel.title = "Choose Hook Scripts"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !paths.contains(url.path) {
            paths.append(url.path)
        }
        MeetingHookSettings.setHookPaths(paths)
    }

    private func runTest() {
        let store = TranscriptStore.shared
        guard let latest = (try? store.fetchAllSessions())?.first else {
            testResult = "No meetings recorded yet."
            return
        }
        isTesting = true
        testResult = nil
        let currentPaths = paths
        Task { @MainActor in
            let failures = await MeetingHooks.runAll(paths: currentPaths, sessionId: latest.id, store: store)
            isTesting = false
            testResult = failures.isEmpty
                ? "All scripts succeeded on “\(latest.title)”."
                : failures.joined(separator: "\n")
        }
    }
}
