// ScribeiOS/Diarization/RecordingSpeakersSection.swift
//
// The speakers of one recording as chips (tap to rename), plus the speaker
// separation status ("Separating speakers…", "Waiting for the charger…").
// Shown on RecordingDetailScreen above the transcript.

import SwiftUI

struct RecordingSpeakersSection: View {
    let sessionId: String
    /// Effective speaker keys in first-appearance order.
    let speakerKeys: [String]
    let resolver: SpeakerNameResolver
    let onRename: (String) -> Void

    @State private var scheduler = IOSDiarizationScheduler.shared

    var body: some View {
        Section {
            if let status = scheduler.status(for: sessionId) {
                HStack(spacing: 8) {
                    if scheduler.runningSessionId == sessionId {
                        ProgressView()
                    } else {
                        Image(systemName: "person.2.wave.2")
                    }
                    Text(status)
                }
                .foregroundStyle(.secondary)
            }
            if !speakerKeys.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(speakerKeys, id: \.self) { key in
                            Button {
                                onRename(key)
                            } label: {
                                Label(resolver.displayName(forKey: key), systemImage: "person.crop.circle")
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityHint("Renames this speaker")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        } header: {
            Text("Speakers")
        } footer: {
            if !speakerKeys.isEmpty {
                Text("Tap a speaker to rename them in this recording.")
            }
        }
    }
}
