import SwiftUI

/// Gallery-style Base view: each record is a card laid out in a responsive
/// grid. Cards show the note title, an excerpt, and a handful of property
/// chips. Honors the active filter + sort via the records the host passes in.
struct BaseCardView: View {

    let records: [BaseRecord]
    /// Property keys rendered as chips on each card.
    let chipKeys: [String]
    var onOpenNote: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: DesignTokens.Spacing.md)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                ForEach(records) { record in
                    card(record)
                        .onTapGesture { onOpenNote(record.note.id) }
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .background(DesignTokens.Palette.surface)
    }

    private func card(_ record: BaseRecord) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(record.note.title.isEmpty ? "Untitled" : record.note.title)
                .font(DesignTokens.Typography.section)
                .lineLimit(2)

            if let excerpt = record.note.bodyExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            let chips = chipKeys.compactMap { key -> (String, PropertyValue)? in
                guard let value = record.value(forKey: key), !value.isEmpty else { return nil }
                return (key, value)
            }
            if !chips.isEmpty {
                FlowChips(chips: chips)
            }

            Spacer(minLength: 0)

            Text(record.note.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .stroke(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// Simple wrapping chip row for property summaries on a card.
private struct FlowChips: View {
    let chips: [(String, PropertyValue)]

    var body: some View {
        // A LazyVGrid with adaptive columns gives a wrap-like layout without a
        // custom Layout — good enough for a handful of property chips.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 60, maximum: 160), spacing: DesignTokens.Spacing.xs, alignment: .leading)],
            alignment: .leading,
            spacing: DesignTokens.Spacing.xs
        ) {
            ForEach(chips, id: \.0) { key, value in
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: value.type.systemImage)
                        .font(.caption2)
                    Text(value.displayString)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.vertical, 2)
                .background(DesignTokens.Palette.surfaceSunken, in: Capsule())
                .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Base Cards") {
    BaseCardView(
        records: BasePreviewData.records,
        chipKeys: ["status", "priority", "due", "starred"],
        onOpenNote: { print("open \($0)") }
    )
    .frame(width: 700, height: 420)
}
