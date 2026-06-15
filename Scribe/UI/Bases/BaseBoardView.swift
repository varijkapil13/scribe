import SwiftUI

/// Kanban-style Base view: records grouped into columns by a `select`-style
/// property (`query.groupBy`). Each column is a vertical stack of cards;
/// columns scroll horizontally. When no group key is set, a hint is shown.
struct BaseBoardView: View {

    let groups: [BaseGroup]
    let groupBy: String?
    /// Property keys surfaced as a one-line summary on each card.
    let summaryKeys: [String]
    var onOpenNote: (String) -> Void

    var body: some View {
        if groupBy == nil {
            ContentUnavailableView(
                "Choose a property to group by",
                systemImage: "rectangle.split.3x1",
                description: Text("Pick a Group property (e.g. status) to arrange notes into board columns.")
            )
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    ForEach(groups) { group in
                        column(group)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
            .background(DesignTokens.Palette.surface)
        }
    }

    private func column(_ group: BaseGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(group.title)
                    .font(DesignTokens.Typography.section)
                    .lineLimit(1)
                Text("\(group.records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .background(DesignTokens.Palette.surfaceSunken, in: Capsule())
            }

            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(group.records) { record in
                        BaseMiniCard(record: record, summaryKeys: summaryKeys)
                            .onTapGesture { onOpenNote(record.note.id) }
                    }
                }
            }
        }
        .frame(width: 260, alignment: .top)
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    }
}

/// Compact card used inside board columns.
struct BaseMiniCard: View {
    let record: BaseRecord
    let summaryKeys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(record.note.title.isEmpty ? "Untitled" : record.note.title)
                .font(DesignTokens.Typography.body)
                .fontWeight(.medium)
                .lineLimit(2)

            ForEach(summaryKeys, id: \.self) { key in
                if let value = record.value(forKey: key), !value.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Text(key)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(value.displayString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .stroke(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

#Preview("Base Board") {
    let query = BaseQuery(groupBy: "status")
    return BaseBoardView(
        groups: query.grouped(BasePreviewData.records),
        groupBy: "status",
        summaryKeys: ["priority", "due"],
        onOpenNote: { print("open \($0)") }
    )
    .frame(width: 700, height: 360)
}
