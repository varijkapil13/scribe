// Scribe/UI/Notes/FormatToolbar.swift
import SwiftUI

@Observable
final class EditorActions {
    var bold: (() -> Void)?
    var italic: (() -> Void)?
    var strikethrough: (() -> Void)?
    var code: (() -> Void)?
    var setHeading: ((Int) -> Void)?  // 0 = paragraph, 1–3 = H1–H3
}

struct FormatToolbar: View {
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 2) {
            ToolbarButton(systemImage: "bold", tooltip: "Bold (⌘B)")        { actions.bold?() }
            ToolbarButton(systemImage: "italic", tooltip: "Italic (⌘I)")     { actions.italic?() }
            ToolbarButton(systemImage: "strikethrough", tooltip: "Strikethrough") { actions.strikethrough?() }
            ToolbarButton(systemImage: "chevron.left.forwardslash.chevron.right", tooltip: "Inline Code (⌘`)") { actions.code?() }

            Divider().frame(height: 16).padding(.horizontal, 4)

            Menu {
                Button("Paragraph") { actions.setHeading?(0) }
                Button("Heading 1") { actions.setHeading?(1) }
                Button("Heading 2") { actions.setHeading?(2) }
                Button("Heading 3") { actions.setHeading?(3) }
            } label: {
                Text("¶ T")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
            .menuStyle(.borderlessButton)
            .help("Paragraph style")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ToolbarButton: View {
    let systemImage: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
