// Scribe/UI/MediaImport/MediaImportViews.swift
import SwiftUI
import UniformTypeIdentifiers

/// Main-window support for importing recordings: accepts audio/video files
/// dropped anywhere on the window (including the note list) and shows the
/// import progress card with Cancel. Applied once in `MainWindowView`.
@MainActor
struct MediaImportWindowSupport: ViewModifier {
    @ObservedObject private var importer = MediaImportController.shared
    @State private var isDropTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.audiovisualContent], isTargeted: $isDropTargeted) { providers in
                MediaImportDrop.handle(providers)
            }
            .overlay {
                if isDropTargeted {
                    MediaImportDropHighlight()
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let progress = importer.progress {
                    MediaImportProgressCard(progress: progress) { importer.cancel() }
                        .padding(DesignTokens.Spacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: importer.progress != nil)
    }
}

// MARK: - Drop

enum MediaImportDrop {

    /// Loads the dropped file URLs and queues the supported ones. Returns
    /// whether the drop was accepted.
    @MainActor
    static func handle(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    MediaImportController.shared.importFiles([url])
                }
            }
        }
        return true
    }
}

private struct MediaImportDropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Label("Drop to import and transcribe", systemImage: "waveform.badge.plus")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(8)
    }
}

// MARK: - Progress card

struct MediaImportProgressCard: View {
    let progress: MediaImportController.Progress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.fileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if !progress.preview.isEmpty {
                Text(progress.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(progress.fileName), \(statusText)")
    }

    private var statusText: String {
        var text: String
        switch progress.stage {
        case .preparing:    text = "Preparing…"
        case .transcribing:
            let percent = Int(((progress.fraction ?? 0) * 100).rounded())
            text = "Transcribing… \(percent)%"
        case .finishing:    text = "Finishing transcription…"
        case .saving:       text = "Saving…"
        }
        if progress.queued > 0 {
            text += " · \(progress.queued) more queued"
        }
        return text
    }
}
