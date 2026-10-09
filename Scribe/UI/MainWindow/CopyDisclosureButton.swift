import SwiftUI

/// Capsule chip for the live session's audio-source row that copies the
/// recording disclosure message (see ``ConsentDisclosure``) to the clipboard,
/// ready to paste into the meeting chat.
struct CopyDisclosureButton: View {
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            ConsentDisclosure.copyToPasteboard()
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: copied ? "checkmark" : "text.bubble")
                    .font(.system(size: 11, weight: .semibold))
                Text(copied ? "Copied" : "Copy Disclosure Message")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(Capsule().fill(DesignTokens.Palette.surfaceElevated))
            .overlay(Capsule().strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Copy a message telling participants you're transcribing, to paste into the meeting chat")
        .accessibilityLabel(copied ? "Disclosure message copied" : "Copy disclosure message")
        .onDisappear { resetTask?.cancel() }
    }
}
