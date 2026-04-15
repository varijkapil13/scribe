import SwiftUI
import CoreAudio

// MARK: - MenuBarPopoverView

/// A SwiftUI view suitable for display in a menu bar popover, providing richer
/// transcription controls than the plain NSMenu approach.
struct MenuBarPopoverView: View {

    @ObservedObject var audioManager: AudioSessionManager

    /// Currently selected microphone device ID. `nil` means system default.
    @State private var selectedMicrophoneID: AudioDeviceID?

    /// Whether system audio capture is enabled.
    @State private var captureSystemAudio: Bool = true

    /// Closure invoked to open the transcript viewer window.
    var onOpenTranscripts: (() -> Void)?

    /// Closure invoked to open the settings window.
    var onOpenSettings: (() -> Void)?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            // Recording indicator and duration
            recordingHeader

            Divider()

            // Transport controls
            transportControls

            Divider()

            // Audio source selectors
            audioSourceSection

            Divider()

            // Navigation buttons
            navigationButtons
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Recording Header

    private var recordingHeader: some View {
        HStack(spacing: 6) {
            if audioManager.isRecording {
                Circle()
                    .fill(audioManager.isPaused ? Color.yellow : Color.red)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(Color.red.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .scaleEffect(audioManager.isPaused ? 1.0 : 1.6)
                            .opacity(audioManager.isPaused ? 0.0 : 0.0)
                            .animation(
                                audioManager.isPaused
                                    ? .default
                                    : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                value: audioManager.isPaused
                            )
                    )
                    .accessibilityLabel(audioManager.isPaused ? "Paused" : "Recording")

                Text(audioManager.isPaused ? "Paused" : "Recording")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(audioManager.isPaused ? .yellow : .red)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Idle")

                Text("Idle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(formattedDuration)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .accessibilityLabel("Duration: \(formattedDuration)")
        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 12) {
            // Start / Stop
            Button(action: {
                Task { await toggleRecording() }
            }) {
                Label(
                    audioManager.isRecording ? "Stop" : "Start",
                    systemImage: audioManager.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(audioManager.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .accessibilityHint(audioManager.isRecording ? "Stops the current transcription session" : "Begins a new transcription session")

            // Pause / Resume (only when recording)
            if audioManager.isRecording {
                Button(action: {
                    Task { await togglePause() }
                }) {
                    Label(
                        audioManager.isPaused ? "Resume" : "Pause",
                        systemImage: audioManager.isPaused ? "play.circle.fill" : "pause.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint(audioManager.isPaused ? "Resumes the paused session" : "Pauses the current session")
            }
        }
    }

    // MARK: - Audio Source Section

    private var audioSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Sources")
                .font(.caption)
                .foregroundColor(.secondary)

            // Microphone picker
            Picker(selection: $selectedMicrophoneID, label: Label("Microphone", systemImage: "mic")) {
                Text("System Default")
                    .tag(AudioDeviceID?.none)

                ForEach(audioManager.availableMicrophones(), id: \.id) { device in
                    Text(device.name)
                        .tag(AudioDeviceID?.some(device.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Microphone selector")

            // System audio toggle
            Toggle(isOn: $captureSystemAudio) {
                Label("Capture System Audio", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Capture system audio")
            .accessibilityHint("Enables recording of desktop and application audio alongside the microphone")
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Button(action: { onOpenTranscripts?() }) {
                Label("Transcripts", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityHint("Opens the transcript viewer window")

            Button(action: { onOpenSettings?() }) {
                Label("Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityHint("Opens the settings window")
        }
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let total = Int(audioManager.recordingDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    @MainActor
    private func toggleRecording() async {
        if audioManager.isRecording {
            await audioManager.stopRecording()
        } else {
            do {
                try await audioManager.startRecording(
                    micDeviceID: selectedMicrophoneID,
                    captureSystemAudio: captureSystemAudio
                )
            } catch {
                // Error handling is deferred to the host application's alert mechanism.
                print("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func togglePause() async {
        if audioManager.isPaused {
            do {
                try await audioManager.resumeRecording()
            } catch {
                print("Failed to resume recording: \(error.localizedDescription)")
            }
        } else {
            audioManager.pauseRecording()
        }
    }
}
