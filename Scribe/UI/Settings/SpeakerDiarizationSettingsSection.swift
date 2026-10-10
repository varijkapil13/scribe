import SwiftUI

/// Settings → Vocabulary → "Telling speakers apart": on-device diarization
/// of the remote side (see `SpeakerDiarization.swift`).
struct SpeakerDiarizationSettingsSection: View {
    @AppStorage(SpeakerDiarizationSettings.enabledKey) private var enabled = true
    @AppStorage(SpeakerDiarizationSettings.allowModelDownloadKey) private var allowDownload = true
    @AppStorage(SpeakerDiarizationSettings.suggestNamesKey) private var suggestNames = true

    var body: some View {
        Section("Telling speakers apart") {
            Toggle("Split remote audio into Speaker 1, 2, 3…", isOn: $enabled)
            Toggle("Suggest names from calendar attendees and the conversation", isOn: $suggestNames)
                .disabled(!enabled)
            if SpeakerDiarizationModels.bundledRoot == nil {
                Toggle("Download the speaker model if needed (about 22 MB, once)", isOn: $allowDownload)
                    .disabled(!enabled)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let model = SpeakerDiarizationModels.bundledRoot != nil
            ? "The speaker model ships with Scribe."
            : "This build doesn't include the speaker model; it's fetched from Hugging Face the first time it's needed. Only the model is downloaded."
        return "After a meeting ends, Scribe separates the other participants' voices on your Mac and labels them Speaker 1, 2, 3, which you can rename. Needs system audio capture. No audio leaves your Mac. \(model) Speaker model: pyannote community-1 via FluidAudio (CC BY 4.0)."
    }
}
