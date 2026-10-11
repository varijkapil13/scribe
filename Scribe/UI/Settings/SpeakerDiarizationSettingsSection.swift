import SwiftUI

/// Settings → Vocabulary → "Telling speakers apart": on-device diarization
/// of the remote side (see `SpeakerDiarization.swift`).
struct SpeakerDiarizationSettingsSection: View {
    @AppStorage(SpeakerDiarizationSettings.enabledKey) private var enabled = true
    @AppStorage(SpeakerDiarizationSettings.allowModelDownloadKey) private var allowDownload = true
    @AppStorage(SpeakerDiarizationSettings.suggestNamesKey) private var suggestNames = true
    @State private var models = ScribeDiarizerModelManager.shared

    var body: some View {
        Section("Telling speakers apart") {
            Toggle("Split remote audio into Speaker 1, 2, 3…", isOn: $enabled)
            Toggle("Suggest names from calendar attendees and the conversation", isOn: $suggestNames)
                .disabled(!enabled)
            Toggle("Download the speaker model automatically (about 22 MB, once)", isOn: $allowDownload)
                .disabled(!enabled)
            modelRow
                .disabled(!enabled)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { models.refresh() }
    }

    @ViewBuilder
    private var modelRow: some View {
        LabeledContent("Speaker model") {
            switch models.state {
            case .installed(let bytes):
                HStack {
                    Text("Downloaded (\(ScribeDiarizerModelStorage.sizeLabel(bytes: bytes)))")
                        .foregroundStyle(.secondary)
                    Button("Delete", role: .destructive) { models.delete() }
                }
            case .downloading(let fraction):
                HStack {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                    Button("Cancel") { models.cancelDownload() }
                }
            case .notInstalled:
                Button("Download (\(ScribeDiarizerModelStorage.sizeLabel(bytes: ScribeDiarizerModelRepository.approximateDownloadBytes)))") {
                    models.download()
                }
            case .failed(let message):
                HStack {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Retry") { models.download() }
                }
            }
        }
    }

    private var caption: String {
        "After a meeting ends, Scribe separates the other participants' voices on your Mac and labels them Speaker 1, 2, 3, which you can rename. Needs system audio capture. No audio leaves your Mac. The speaker model isn't included in the app download; Scribe fetches it from Hugging Face once, shortly after installation. Only the model is downloaded. Speaker model: pyannote community-1 via FluidAudio (CC BY 4.0)."
    }
}
