// ScribeiOS/Diarization/SpeakerSeparationSettingsScreen.swift
//
// Settings › Speakers on iPhone / iPad: speaker separation on/off, name
// suggestions, and the downloadable speaker model (size, download progress,
// delete, Wi‑Fi only). Wired into SettingsScreen with one row at the
// recording slot.

import SwiftUI

/// The row in the settings root.
struct SpeakerSeparationSettingsRow: View {
    var body: some View {
        Section {
            NavigationLink {
                SpeakerSeparationSettingsScreen()
            } label: {
                Label("Speakers", systemImage: "person.2.wave.2")
            }
        }
    }
}

struct SpeakerSeparationSettingsScreen: View {
    @AppStorage(IOSDiarizationSettings.enabledKey) private var enabled = true
    @AppStorage(IOSDiarizationSettings.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(IOSDiarizationSettings.suggestNamesKey) private var suggestNames = true

    @State private var models = IOSDiarizationModelManager.shared
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Toggle("Separate speakers after recording", isOn: Binding(
                    get: { enabled },
                    set: { setEnabled($0) }
                ))
                Toggle("Suggest speaker names", isOn: $suggestNames)
                    .disabled(!enabled)
            } footer: {
                Text("Tells the voices in a recording apart and labels them Speaker 1, Speaker 2… — rename them on the recording. Runs on this device right after recording when it's charging or above 30 percent battery and not too warm; otherwise later, usually while charging. Names are suggested on-device from calendar attendees and the conversation.")
            }

            Section {
                modelRow
                Toggle("Download on Wi‑Fi only", isOn: $wifiOnly)
            } header: {
                Text("Speaker Model")
            } footer: {
                Text("The model (about \(ScribeDiarizerModelStorage.sizeLabel(bytes: ScribeDiarizerModelRepository.approximateDownloadBytes))) downloads once, the first time it's needed. It isn't included in iCloud or device backups. Only the model is downloaded; your audio never leaves this device.")
            }
        }
        .navigationTitle("Speakers")
        .onAppear { models.refresh() }
        .confirmationDialog("Delete the speaker model?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Model", role: .destructive) { models.delete() }
        } message: {
            Text("Speaker separation downloads it again the next time it's needed.")
        }
    }

    @ViewBuilder private var modelRow: some View {
        switch models.state {
        case .notInstalled:
            LabeledContent("Not downloaded",
                           value: ScribeDiarizerModelStorage.sizeLabel(bytes: ScribeDiarizerModelRepository.approximateDownloadBytes))
            Button("Download Now", systemImage: "arrow.down.circle") { models.download() }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading…")
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
            }
            Button("Cancel Download", role: .cancel) { models.cancelDownload() }
        case .installed(let bytes):
            LabeledContent("Downloaded", value: ScribeDiarizerModelStorage.sizeLabel(bytes: bytes))
            Button("Delete Model", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try Again", systemImage: "arrow.clockwise") { models.download() }
        }
    }

    private func setEnabled(_ value: Bool) {
        enabled = value
        if value {
            IOSDiarizationScheduler.shared.drainIfPossible()
        } else {
            IOSDiarizationScheduler.shared.discardQueuedJobs()
        }
    }
}
