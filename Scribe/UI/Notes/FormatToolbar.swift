// Scribe/UI/Notes/FormatToolbar.swift
import SwiftUI

@Observable
final class EditorActions {
    var bold: (() -> Void)?
    var italic: (() -> Void)?
    var strikethrough: (() -> Void)?
    var code: (() -> Void)?
    var link: (() -> Void)?
    var blockquote: (() -> Void)?
    var unorderedList: (() -> Void)?
    var orderedList: (() -> Void)?
    var setHeading: ((Int) -> Void)?  // 0 = paragraph, 1–3 = H1–H3
}

struct FormatToolbar: View {
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 0) {
            ToolbarButton(systemImage: "bold",          tooltip: "Bold (⌘B)")              { actions.bold?() }
            ToolbarButton(systemImage: "italic",        tooltip: "Italic (⌘I)")             { actions.italic?() }
            ToolbarButton(systemImage: "strikethrough", tooltip: "Strikethrough (⌘⇧X)")    { actions.strikethrough?() }
            ToolbarButton(systemImage: "chevron.left.forwardslash.chevron.right",
                                                        tooltip: "Inline Code (⌘`)")       { actions.code?() }
            ToolbarButton(systemImage: "link",          tooltip: "Link (⌘K)")              { actions.link?() }

            Divider().frame(height: 20).padding(.horizontal, 6)

            Menu {
                Button("Paragraph")  { actions.setHeading?(0) }
                Divider()
                Button("Heading 1")  { actions.setHeading?(1) }
                Button("Heading 2")  { actions.setHeading?(2) }
                Button("Heading 3")  { actions.setHeading?(3) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "textformat.size")
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 32)
                .padding(.horizontal, 8)
            }
            .menuStyle(.borderlessButton)
            .help("Paragraph style")
            .fixedSize()

            Divider().frame(height: 20).padding(.horizontal, 6)

            ToolbarButton(systemImage: "text.quote",   tooltip: "Blockquote (⌘⇧.)")       { actions.blockquote?() }
            ToolbarButton(systemImage: "list.bullet",  tooltip: "Bullet List (⌘⇧8)")      { actions.unorderedList?() }
            ToolbarButton(systemImage: "list.number",  tooltip: "Numbered List (⌘⇧7)")    { actions.orderedList?() }

            Spacer()
        }
        .padding(.horizontal, 10)
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
                .imageScale(.medium)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
