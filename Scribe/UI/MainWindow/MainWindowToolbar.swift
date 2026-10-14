import SwiftUI
import TipKit

/// The main window's customizable toolbar (`.toolbar(id: MainWindowToolbar.id)`).
///
/// Back/Forward share one glass group; the search capsule opens the command
/// bar; the Record capsule starts a session and becomes Stop (plus Pause and the
/// status pill) while recording. New Note is available from View › Customize
/// Toolbar…. SwiftUI persists the user's arrangement under the toolbar id.
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
            .popoverTip(ScribeTips.dictation)
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

        ToolbarItem(id: "recordingStatus", placement: .navigation) {
            if isRecording {
                RecordingStatusPill(status: appState.recordingStatus, clock: appState.recordingClock)
                    .onTapGesture { onShowLive() }
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "newNote", placement: .primaryAction) {
            Button {
                onNewNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New note (⌘N)")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "commandBar", placement: .navigation) {
            ToolbarSearchCapsule {
                onCommandBar()
                ScribeTips.quickSearchUsed()
            }
            .popoverTip(ScribeTips.quickSearch)
        }
        .sharedBackgroundVisibility(.hidden)

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
            ToolbarRecordCapsule(isRecording: isRecording) {
                ScribeTips.recordUsed()
                onToggleRecording()
            }
            .popoverTip(ScribeTips.record)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

private struct ToolbarSearchCapsule: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                Text("Search or jump to…")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                Text("⌘K")
                    .padding(.leading, DesignTokens.Spacing.lg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: DesignTokens.Metrics.toolbarCapsuleHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scribeFloatingGlass(in: Capsule(), interactive: true)
        .help("Search and commands (⌘K)")
        .accessibilityLabel("Search or jump to")
    }
}

private struct ToolbarRecordCapsule: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isRecording {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(DesignTokens.Palette.recording)
                        .frame(width: 9, height: 9)
                } else {
                    Circle()
                        .fill(DesignTokens.Palette.recording)
                        .frame(width: 9, height: 9)
                }
                Text(isRecording ? "Stop" : "Record")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(height: DesignTokens.Metrics.toolbarCapsuleHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scribeFloatingGlass(in: Capsule(), interactive: true)
        .help(isRecording ? "Stop the current session" : "Start a new recording")
        .accessibilityLabel(isRecording ? "Stop" : "Record")
    }
}
