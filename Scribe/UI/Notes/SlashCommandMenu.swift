// Scribe/UI/Notes/SlashCommandMenu.swift
import SwiftUI

/// A block-insert command surfaced by the slash `/` menu. Each command routes
/// to an existing `EditorActions` verb so the menu adds no new editing paths —
/// it's purely a keyboard-driven entry point to what the toolbar already does.
struct SlashCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    /// Keywords matched in addition to the title (e.g. "h1" matches "Heading 1").
    let keywords: [String]
    /// The verb to run on `EditorActions` after the typed `/query` is removed.
    let run: (EditorActions) -> Void

    static func == (lhs: SlashCommand, rhs: SlashCommand) -> Bool { lhs.id == rhs.id }

    /// Whether this command matches the typed query (case-insensitive prefix /
    /// substring over the title and keywords). An empty query matches all.
    func matches(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        return keywords.contains { $0.lowercased().hasPrefix(q) || $0.lowercased().contains(q) }
    }
}

extension SlashCommand {
    /// The full palette, ordered to match Craft / Notion conventions. Built on
    /// the main actor — the closures call into `EditorActions`, which is
    /// MainActor-bound UI plumbing.
    @MainActor static let all: [SlashCommand] = [
        SlashCommand(id: "h1", title: "Heading 1", subtitle: "Big section title",
                     symbol: "textformat.size.larger", keywords: ["h1", "title", "heading"],
                     run: { $0.setHeading?(1) }),
        SlashCommand(id: "h2", title: "Heading 2", subtitle: "Medium section title",
                     symbol: "textformat.size", keywords: ["h2", "subtitle", "heading"],
                     run: { $0.setHeading?(2) }),
        SlashCommand(id: "h3", title: "Heading 3", subtitle: "Small section title",
                     symbol: "textformat.size.smaller", keywords: ["h3", "heading"],
                     run: { $0.setHeading?(3) }),
        SlashCommand(id: "bullet", title: "Bulleted List", subtitle: "Unordered list",
                     symbol: "list.bullet", keywords: ["bullet", "unordered", "ul", "list"],
                     run: { $0.unorderedList?() }),
        SlashCommand(id: "numbered", title: "Numbered List", subtitle: "Ordered list",
                     symbol: "list.number", keywords: ["numbered", "ordered", "ol", "list"],
                     run: { $0.orderedList?() }),
        SlashCommand(id: "checklist", title: "Checklist", subtitle: "To-do items",
                     symbol: "checklist", keywords: ["checklist", "todo", "task", "checkbox"],
                     run: { $0.checklist?() }),
        SlashCommand(id: "quote", title: "Quote", subtitle: "Blockquote",
                     symbol: "text.quote", keywords: ["quote", "blockquote", "cite"],
                     run: { $0.blockquote?() }),
        SlashCommand(id: "code", title: "Code Block", subtitle: "Monospaced block",
                     symbol: "curlybraces", keywords: ["code", "fence", "monospace"],
                     run: { $0.insertCodeBlock?() }),
        SlashCommand(id: "divider", title: "Divider", subtitle: "Horizontal rule",
                     symbol: "minus", keywords: ["divider", "rule", "hr", "separator"],
                     run: { $0.insertDivider?() }),
        SlashCommand(id: "table", title: "Table", subtitle: "2×2 starter table",
                     symbol: "tablecells", keywords: ["table", "grid"],
                     run: { $0.insertTable?() }),
        SlashCommand(id: "image", title: "Image", subtitle: "Insert image markdown",
                     symbol: "photo", keywords: ["image", "picture", "photo"],
                     run: { $0.insertImagePlaceholder?() }),
    ]
}

/// Keyboard-driven slash command menu shown at the caret. Filters as the user
/// types after `/`, navigable with arrows + Return, dismissed with Esc — all
/// driven from the host text view (which keeps first-responder so typing keeps
/// filtering). Backed by a translucent material that collapses to a solid
/// surface under Reduce Transparency / Increase Contrast.
struct SlashCommandMenu: View {
    let query: String
    /// Index of the highlighted row, owned by the host so the text view's key
    /// interception can drive it without stealing focus.
    @Binding var highlighted: Int
    let onPick: (SlashCommand) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Commands matching the current query — exposed statically so the host can
    /// compute the same list for key handling and committing.
    @MainActor static func filtered(for query: String) -> [SlashCommand] {
        SlashCommand.all.filter { $0.matches(query) }
    }

    private var rows: [SlashCommand] { Self.filtered(for: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No matching blocks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, command in
                    row(command, isHighlighted: index == clampedHighlight(rows.count))
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(command) }
                        .onHover { hovering in
                            if hovering { highlighted = index }
                        }
                }
            }
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(width: 280)
        .background(menuBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insert block")
        .accessibilityHint("Type to filter. Up and down arrows to choose, Return to insert, Escape to dismiss.")
    }

    // MARK: - Row

    private func row(_ command: SlashCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: command.symbol)
                .frame(width: 22, height: 22)
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(command.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(isHighlighted ? highlightFill : .clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(command.title), \(command.subtitle)")
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Highlight clamping

    private func clampedHighlight(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, highlighted), count - 1)
    }

    // MARK: - Styling (a11y-aware)

    @ViewBuilder
    private var menuBackground: some View {
        if reduceTransparency || contrast == .increased {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surfaceElevated)
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private var borderColor: Color {
        contrast == .increased ? Color.primary.opacity(0.30) : DesignTokens.Palette.cardBorder
    }

    private var highlightFill: Color {
        contrast == .increased ? Color.accentColor.opacity(0.30) : Color.accentColor.opacity(0.15)
    }
}
