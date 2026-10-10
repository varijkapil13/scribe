import SwiftUI

/// Rows under "Capture system audio" in General → Audio: which backend
/// captures other apps' audio, whether the tap narrows to the meeting app,
/// and — when Scribe suspects System Audio Recording was denied — a way to
/// fix it and try the tap again.
struct SystemAudioSourceSettings: View {
    /// Whether system-audio capture is on at all.
    let captureEnabled: Bool

    @AppStorage(SystemAudioSourcePreference.defaultsKey)
    private var source: SystemAudioSourcePreference = SystemAudioSourcePreference.defaultValue
    @AppStorage(SystemAudioTapSettings.meetingAppOnlyKey)
    private var meetingAppOnly: Bool = false
    @AppStorage(ProcessTapPermissionState.defaultsKey)
    private var tapPermission: ProcessTapPermissionState = ProcessTapPermissionState.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Picker("System audio source", selection: $source) {
                ForEach(SystemAudioSourcePreference.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Text(sourceCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!captureEnabled)

        if source == .automatic {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Toggle("Capture only the meeting app's audio", isOn: $meetingAppOnly)
                Text("When a call app was detected, Scribe taps just that app, so notification sounds and music from other apps stay out of the transcript. Falls back to all apps when the meeting app isn't playing audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!captureEnabled)

            if tapPermission == .suspectedDenied {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Label(
                        "The Core Audio tap only heard silence, so System Audio Recording may be turned off for Scribe. Scribe uses ScreenCaptureKit instead when Screen Recording is allowed.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Privacy Settings…") {
                            Permissions.openSystemPreferences(for: "Privacy_ScreenCapture")
                        }
                        Button("Try the Tap Again") {
                            tapPermission = .unknown
                        }
                    }
                }
            }
        }
    }

    private var sourceCaption: String {
        switch source {
        case .automatic:
            return "Uses a Core Audio tap of every app except Scribe (needs System Audio Recording permission, which macOS asks for on first use). Falls back to ScreenCaptureKit if the tap can't run."
        case .screenCaptureKit:
            return "Uses ScreenCaptureKit, which needs Screen Recording permission."
        }
    }
}
