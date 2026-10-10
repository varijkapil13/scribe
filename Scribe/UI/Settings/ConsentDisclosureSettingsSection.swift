import SwiftUI

/// "Recording disclosure" section of General settings: the message to share
/// with meeting participants and whether to copy it when recording starts.
struct ConsentDisclosureSettingsSection: View {
    @AppStorage(ConsentDisclosure.textKey) private var text: String = ConsentDisclosure.defaultText
    @AppStorage(ConsentDisclosure.copyOnStartKey) private var copyOnStart: Bool = false
    @State private var copied = false

    var body: some View {
        Section("Recording disclosure") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Toggle("Copy disclosure message when recording starts", isOn: $copyOnStart)
                Text("Puts the message below on your clipboard and lets you know, so you can paste it into the meeting chat. You can also copy it any time from the menu bar or the live recording view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Message")
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 56, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                    )
                    .accessibilityLabel("Disclosure message")
            }

            HStack {
                Button("Reset to Default") { text = ConsentDisclosure.defaultText }
                    .disabled(text == ConsentDisclosure.defaultText)
                Spacer()
                if copied {
                    Text("Copied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Copy Now") {
                    ConsentDisclosure.copyToPasteboard()
                    copied = true
                }
            }
            .onChange(of: text) { _, _ in copied = false }
        }
    }
}
