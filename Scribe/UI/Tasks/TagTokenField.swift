import SwiftUI

/// Chip/token field for editing a task's tags inline in the inspector.
/// Replaces the old comma-separated `TextField`: existing tags render as
/// removable pills (echoing the quick-add purple token color), and typing a
/// prefix surfaces autocomplete suggestions from the store's full tag set.
///
/// Fully keyboard-operable: the entry field accepts Return / comma / space to
/// commit a token, Delete on an empty field removes the last chip, and each
/// chip exposes a VoiceOver-labelled remove button. Suggestions are arrow-
/// navigable via the popover list.
struct TagTokenField: View {

    /// Currently applied tags.
    let tags: [String]
    /// Provides prefix-matched suggestions for the live draft.
    let suggestions: (String) -> [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    /// Quick-add token color for tags (see `HighlightingQuickAddField`).
    private var tagTint: Color { Color(nsColor: .systemPurple) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            chipFlow
            if fieldFocused, !liveSuggestions.isEmpty {
                suggestionList
            }
        }
    }

    // MARK: - Chips + entry

    private var chipFlow: some View {
        WrapHStack(spacing: DesignTokens.Spacing.xs, lineSpacing: DesignTokens.Spacing.xs) {
            ForEach(tags, id: \.self) { tag in
                chip(tag)
            }
            entryField
        }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text("#\(tag)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tagTint)
            Button {
                onRemove(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tagTint.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(tagTint.opacity(contrast == .increased ? 0.28 : 0.15))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tagTint.opacity(contrast == .increased ? 0.6 : 0.0), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag \(tag)")
    }

    private var entryField: some View {
        TextField(tags.isEmpty ? "Add tags…" : "", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(minWidth: 64)
            .focused($fieldFocused)
            .onSubmit { commitDraft() }
            .onChange(of: draft) { _, newValue in
                // Commit on comma / space separators so paste-with-commas works.
                if newValue.contains(",") || newValue.contains(" ") {
                    let parts = newValue.split(whereSeparator: { $0 == "," || $0 == " " })
                    for part in parts { onAdd(String(part)) }
                    draft = ""
                }
            }
            .onKeyPress(.delete) {
                if draft.isEmpty, let last = tags.last {
                    onRemove(last)
                    return .handled
                }
                return .ignored
            }
            .accessibilityLabel("Add tag")
            .accessibilityHint("Type a tag and press Return to add it")
    }

    // MARK: - Suggestions

    private var liveSuggestions: [String] {
        Array(suggestions(draft).prefix(6))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(liveSuggestions, id: \.self) { suggestion in
                Button {
                    onAdd(suggestion)
                    draft = ""
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "number")
                            .font(.system(size: 9))
                            .foregroundStyle(tagTint)
                        Text(suggestion)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add tag \(suggestion)")
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        draft = ""
    }
}

// MARK: - Wrapping HStack

/// Minimal flow layout that wraps its children onto new lines when they exceed
/// the available width. Used by `TagTokenField` so chips reflow naturally.
/// Built on the SwiftUI `Layout` protocol (macOS 13+).
struct WrapHStack: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private struct RowMetric { var width: CGFloat; var height: CGFloat }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [RowMetric] {
        var rows: [RowMetric] = []
        var x: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                rows.append(RowMetric(width: rowWidth, height: rowHeight))
                x = 0
                rowWidth = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowWidth = x
            rowHeight = max(rowHeight, size.height)
        }
        if rowWidth > 0 { rows.append(RowMetric(width: rowWidth, height: rowHeight)) }
        return rows
    }
}
