import SwiftUI

/// Destination a user can navigate to from the main window's sidebar. Combines
/// transcript sessions with settings panes and, while a session is running,
/// the live-recording view so there's only ever one window to look at.
enum MainSelection: Hashable {
    case live
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
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 920, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RecordingStatusPill(audioManager: appState.audioManager, appState: appState)
                    .onTapGesture {
                        if appState.isTranscribing {
                            selection = .live
                        }
                    }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                recordingToolbar
            }
        }
        .onAppear {
            viewModel.loadSessions()
            if selection == nil {
                if appState.isTranscribing {
                    selection = .live
                } else if let first = viewModel.filteredSessions.first {
                    selection = .transcript(first.id)
                }
                // Otherwise stay `.none` and show the Welcome hero.
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScribeSettings)) { note in
            let pane = (note.object as? SettingsPane) ?? .general
            selection = .settings(pane)
        }
        .onChange(of: appState.isTranscribing) { _, isRecording in
            // Session started → flip to the inline live view so the user
            // immediately sees the streaming transcript. Session ended → reload
            // the list and select the just-finished transcript so the post-
            // session summary/analysis flow is one click away.
            if isRecording {
                withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                    selection = .live
                }
            } else {
                viewModel.loadSessions()
                if let first = viewModel.filteredSessions.first {
                    withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                        selection = .transcript(first.id)
                    }
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
            if appState.isTranscribing {
                Section {
                    NavigationLink(value: MainSelection.live) {
                        LiveSidebarRow(
                            isPaused: appState.audioManager.isPaused,
                            duration: appState.audioManager.recordingDuration
                        )
                    }
                } header: {
                    Text("Now")
                        .eyebrowStyle()
                }
            }

            Section {
                if viewModel.filteredSessions.isEmpty {
                    sidebarEmptyHint
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
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Transcripts")
                        .eyebrowStyle()
                    Spacer()
                    if !viewModel.filteredSessions.isEmpty {
                        Text("\(viewModel.filteredSessions.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink(value: MainSelection.settings(pane)) {
                        Label(pane.title, systemImage: pane.systemImage)
                    }
                }
            } header: {
                Text("Settings")
                    .eyebrowStyle()
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts…")
        .onChange(of: searchText) { _, newValue in
            viewModel.search(query: newValue)
        }
        .navigationTitle("Scribe")
    }

    private var sidebarEmptyHint: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.tertiary)
                .font(.callout)
                .padding(.top, 2)
            Text("No transcripts yet. Start a recording to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .live:
            LiveSessionView()
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
            WelcomeView(
                isRecording: appState.isTranscribing,
                onRecord: { Task { await appDelegate.toggleRecording() } }
            )
        }
    }
}

// MARK: - Live sidebar row

/// Compact "Now Recording" entry shown at the top of the sidebar while a
/// session is active. Pulses a recording dot and shows tabular elapsed time
/// so the user can always jump back to the live view, no matter where they
/// browsed off to.
private struct LiveSidebarRow: View {
    let isPaused: Bool
    let duration: TimeInterval

    @State private var pulse: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(showHalo ? (0.9 + pulse * 0.5) : 0.6)
                    .opacity(showHalo ? (0.6 - pulse * 0.6) : 0)
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(isPaused ? "Paused" : "Recording")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(formatted(duration))
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = 1
            }
        }
    }

    private var tint: Color {
        isPaused ? DesignTokens.Palette.paused : DesignTokens.Palette.recording
    }

    private var showHalo: Bool { !isPaused && !reduceMotion }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Welcome state

/// First-run / empty-selection hero. Big serif headline, short supporting
/// copy, one oversized capsule Record CTA, and a calm keyboard-shortcut
/// hint — nothing else. No cards, no badges, no marketing chrome.
private struct WelcomeView: View {

    let isRecording: Bool
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xxl) {
            Spacer()

            VStack(spacing: DesignTokens.Spacing.lg) {
                Text("SCRIBE")
                    .eyebrowStyle()

                Text(isRecording ? "Listening." : "Ready when you are.")
                    .font(DesignTokens.Typography.display)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("On-device speech recognition for meetings, interviews, and anything else worth remembering. Nothing leaves your Mac.")
                    .font(.system(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HeroRecordButton(isRecording: isRecording, action: onRecord)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("or press")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                KeyCapGroup(keys: ["⇧", "⌘", "R"])
                Text("from anywhere")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xxxl)
        .background(DesignTokens.Palette.surface)
    }
}

/// Tiny inline "keyboard key caps" renderer for shortcut hints.
private struct KeyCapGroup: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DesignTokens.Palette.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let openScribeSettings = Notification.Name("scribe.openSettings")
}
