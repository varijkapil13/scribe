// Scribe/UI/Notes/FormatBubble.swift
import SwiftUI

/// Selection-anchored floating format bubble (Craft-style). Appears above a
/// non-empty selection and offers inline formatting + a "turn into" block menu,
/// all routed through the existing `EditorActions` verbs. It never becomes
/// first responder (so the text view keeps its selection) — buttons act and the
/// caret stays put. Backed by Liquid Glass that collapses to a solid
/// surface under Reduce Transparency / Increase Contrast; its entrance is gated
/// on Reduce Motion.
struct FormatBubble: View {
    let actions: EditorActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            bubbleButton("bold", label: "Bold", hint: "Command B") { actions.bold?() }
            bubbleButton("italic", label: "Italic", hint: "Command I") { actions.italic?() }
            bubbleButton("strikethrough", label: "Strikethrough", hint: "Command Shift X") { actions.strikethrough?() }
            bubbleButton("chevron.left.forwardslash.chevron.right",
                         label: "Inline code", hint: "Command Backtick") { actions.code?() }
            bubbleButton("link", label: "Link", hint: "Command K") { actions.link?() }

            Divider().frame(height: 18).padding(.horizontal, DesignTokens.Spacing.xxs)

            Menu {
                Button("Paragraph") { actions.setHeading?(0) }
                Divider()
                Button("Heading 1") { actions.setHeading?(1) }
                Button("Heading 2") { actions.setHeading?(2) }
                Button("Heading 3") { actions.setHeading?(3) }
                Divider()
                Button("Bulleted List") { actions.unorderedList?() }
                Button("Numbered List") { actions.orderedList?() }
                Button("Checklist") { actions.checklist?() }
                Button("Quote") { actions.blockquote?() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "text.alignleft")
                    Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.tertiary)
                }
                .frame(height: 28)
                .padding(.horizontal, 6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Turn into…")
            .accessibilityLabel("Turn into block type")
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.vertical, 3)
        // Liquid Glass; opaque under Reduce Transparency / Increase Contrast.
        .scribeFloatingGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .transition(reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format selection")
    }

    // MARK: - Button

    private func bubbleButton(_ symbol: String, label: String, hint: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

}
