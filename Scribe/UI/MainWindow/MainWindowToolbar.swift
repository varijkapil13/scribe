import SwiftUI

/// The main window's customizable toolbar (`.toolbar(id: MainWindowToolbar.id)`).
///
/// Back, the recording status pill and the Pause/Record transport are shown by
/// default (the toolbar Scribe always had); Forward, New Note and Command Bar
/// are available from View › Customize Toolbar…. SwiftUI persists the user's
/// arrangement under the toolbar id.
@MainActor
struct MainWindowToolbar: CustomizableToolbarContent {
    static let id = "scribe.main"

    let appState: AppState
    let canGoBack: Bool
    let canGoForward: Bool
    let isRecording: Bool
    let isPaused: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onShowLive: () -> Void
    let onTogglePause: () -> Void
    let onToggleRecording: () -> Void
    let onNewNote: () -> Void
    let onCommandBar: () -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "back", placement: .navigation) {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .help("Back (⌘[)")
            .accessibilityLabel("Back")
            .disabled(!canGoBack)
        }

        ToolbarItem(id: "forward", placement: .navigation) {
            Button {
                onForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
            .disabled(!canGoForward)
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "recordingStatus", placement: .navigation) {
            RecordingStatusPill(audioManager: appState.audioManager, appState: appState)
                .onTapGesture {
                    if isRecording { onShowLive() }
                }
        }

        ToolbarItem(id: "newNote", placement: .primaryAction) {
            Button {
                onNewNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New note (⌘N)")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "commandBar", placement: .primaryAction) {
            Button {
                onCommandBar()
            } label: {
                Label("Command Bar", systemImage: "command")
            }
            .help("Command bar (⌘K)")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "pauseResume", placement: .primaryAction) {
            if isRecording {
                Button {
                    onTogglePause()
                } label: {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .help(isPaused ? "Resume recording" : "Pause recording")
            }
        }

        ToolbarItem(id: "record", placement: .primaryAction) {
            Button {
                onToggleRecording()
            } label: {
                Label(
                    isRecording ? "Stop" : "Record",
                    systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                )
                .foregroundStyle(isRecording ? DesignTokens.Palette.recording : .primary)
            }
            .help(isRecording ? "Stop the current session" : "Start a new recording")
        }
    }
}
