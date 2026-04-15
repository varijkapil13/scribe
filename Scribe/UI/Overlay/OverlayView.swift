import SwiftUI

// MARK: - DisplaySegment

/// A view-level model representing a single transcript segment for display in the overlay.
struct DisplaySegment: Identifiable, Equatable {

    let id: UUID
    let timestamp: String
    let speaker: String
    let text: String

    /// Derives a speaker colour based on role keywords.
    var speakerColor: Color {
        let lower = speaker.lowercased()
        if lower == "you" || lower.contains("you") {
            return .blue
        } else if lower == "remote" || lower.contains("remote") {
            return .green
        } else {
            return .secondary
        }
    }

    // MARK: - Convenience Initializer from Storage Segment

    /// Creates a display segment from the storage-layer `Segment` model.
    init(from segment: Segment) {
        self.id = UUID()
        self.timestamp = segment.formattedTimestamp
        self.speaker = segment.speaker
        self.text = segment.text
    }

    init(id: UUID = UUID(), timestamp: String, speaker: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - OverlayView

/// SwiftUI view displayed inside the ``OverlayPanel``, showing the live transcript
/// along with recording status and basic controls.
struct OverlayView: View {

    @ObservedObject var audioManager: AudioSessionManager

    /// The live-updating array of transcript segments.
    @State var segments: [DisplaySegment] = []

    /// Whether the overlay should remain on top of all windows.
    @State private var alwaysOnTop: Bool = true

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            transcriptScrollArea
        }
        .frame(minWidth: 250, minHeight: 200)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Transcript Overlay")
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            if audioManager.isRecording && !audioManager.isPaused {
                recordingIndicator
                Text("Recording")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
            } else if audioManager.isPaused {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Paused")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.yellow)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Idle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(formattedDuration)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .accessibilityLabel("Duration: \(formattedDuration)")

            Button(action: { alwaysOnTop.toggle() }) {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin.slash")
                    .font(.caption)
                    .foregroundColor(alwaysOnTop ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(alwaysOnTop ? "Floating enabled" : "Floating disabled")
            .accessibilityHint("Toggles whether the overlay stays above all windows")
            .onChange(of: alwaysOnTop) { newValue in
                updatePanelFloatingState(newValue)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Recording Indicator

    private var recordingIndicator: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(Color.red.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .scaleEffect(1.6)
                    .opacity(0.6)
                    .animation(
                        .easeInOut(duration: 0.8)
                            .repeatForever(autoreverses: true),
                        value: audioManager.isRecording
                    )
            )
            .accessibilityLabel("Recording active")
    }

    // MARK: - Transcript Scroll Area

    private var transcriptScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        segmentRow(segment)
                            .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: segments.count) { _ in
                if let last = segments.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Segment Row

    private func segmentRow(_ segment: DisplaySegment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(segment.timestamp)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(segment.speaker)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(segment.speakerColor)
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.speaker) at \(segment.timestamp): \(segment.text)")
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let total = Int(audioManager.recordingDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Updates the panel's floating window level when the always-on-top toggle changes.
    private func updatePanelFloatingState(_ shouldFloat: Bool) {
        guard let panel = NSApp.windows.compactMap({ $0 as? OverlayPanel }).first else { return }
        panel.level = shouldFloat ? .floating : .normal
        panel.isFloatingPanel = shouldFloat
    }
}
