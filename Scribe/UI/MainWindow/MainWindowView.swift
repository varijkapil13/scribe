import SwiftUI

/// Destination a user can navigate to from the main window's sidebar. Combines
/// transcript sessions with settings panes so Scribe has a single primary
/// window.
enum MainSelection: Hashable {
    case transcript(String) // session id
    case settings(SettingsPane)
}

/// The main window — sidebar of past transcripts + settings panes, detail
/// pane shows whichever is selected. Primary UI for the app.
struct MainWindowView: View {

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var viewModel = TranscriptListViewModel()
    @State private var searchText: String = ""
    @State private var selection: MainSelection?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                recordingToolbar
            }
        }
        .onAppear {
            viewModel.loadSessions()
            if selection == nil {
                // Default to the latest transcript, or General settings if
                // the database is empty.
                if let first = viewModel.filteredSessions.first {
                    selection = .transcript(first.id)
                } else {
                    selection = .settings(.general)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScribeSettings)) { note in
            let pane = (note.object as? SettingsPane) ?? .general
            selection = .settings(pane)
        }
        .onChange(of: appState.isTranscribing) { _, isRecording in
            // Once a session finishes we want its row to appear in the sidebar
            // and be auto-selected, mirroring how most capture tools behave.
            if !isRecording {
                viewModel.loadSessions()
                if let first = viewModel.filteredSessions.first {
                    selection = .transcript(first.id)
                }
            }
        }
    }

    // MARK: - Recording Toolbar

    @ViewBuilder
    private var recordingToolbar: some View {
        let isRecording = appState.isTranscribing
        let isPaused = appState.audioManager.isPaused

        if isRecording {
            Button {
                if isPaused {
                    Task { await appDelegate.resumeRecording() }
                } else {
                    appDelegate.pauseRecording()
                }
            } label: {
                Label(isPaused ? "Resume" : "Pause",
                      systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused ? "Resume recording" : "Pause recording")
        }

        Button {
            Task { await appDelegate.toggleRecording() }
        } label: {
            Label(
                isRecording ? "Stop" : "Record",
                systemImage: isRecording ? "stop.circle.fill" : "record.circle"
            )
            .foregroundStyle(isRecording ? DesignTokens.Palette.recording : .primary)
        }
        .help(isRecording ? "Stop the current session" : "Start a new recording")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Transcripts") {
                if viewModel.filteredSessions.isEmpty {
                    Text("No transcripts yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                } else {
                    ForEach(viewModel.filteredSessions) { session in
                        NavigationLink(value: MainSelection.transcript(session.id)) {
                            SessionRowView(session: session)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                viewModel.deleteSession(session)
                                if case .transcript(let id) = selection, id == session.id {
                                    selection = viewModel.filteredSessions.first.map { .transcript($0.id) }
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section("Settings") {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink(value: MainSelection.settings(pane)) {
                        Label(pane.title, systemImage: pane.systemImage)
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .onChange(of: searchText) { _, newValue in
            viewModel.search(query: newValue)
        }
        .navigationTitle("Scribe")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .transcript(let id):
            if let session = viewModel.filteredSessions.first(where: { $0.id == id }) {
                TranscriptDetailView(session: session)
                    .id(session.id)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: "Transcript not found",
                    message: "The selected session is no longer available."
                )
            }
        case .settings(let pane):
            SettingsPaneView(pane: pane, audioManager: appState.audioManager)
        case .none:
            EmptyStateView(
                systemImage: "waveform",
                title: "Welcome to Scribe",
                message: "Hit the Record button in the toolbar to start a new session, or pick a past transcript from the sidebar."
            )
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let openScribeSettings = Notification.Name("scribe.openSettings")
}
