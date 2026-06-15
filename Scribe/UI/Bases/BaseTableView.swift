import SwiftUI

/// Spreadsheet-style Base view: one row per note, one column per property.
/// Columns are the keys discovered across the result set (capped to a sane
/// default); the first column is always the note title. Clicking a row asks
/// the host to open that note.
struct BaseTableView: View {

    let records: [BaseRecord]
    let columns: [String]
    @Binding var sort: BaseSort?
    var onOpenNote: (String) -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(records) { record in
                        row(for: record)
                        Divider().opacity(0.4)
                    }
                } header: {
                    headerRow
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
        }
        .background(DesignTokens.Palette.surface)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            headerCell("Title", key: "title", width: 220)
            ForEach(columns, id: \.self) { key in
                headerCell(key, key: key, width: 150)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Palette.surfaceElevated)
    }

    private func headerCell(_ label: String, key: String, width: CGFloat) -> some View {
        Button {
            if sort?.key == key {
                sort?.ascending.toggle()
            } else {
                sort = BaseSort(key: key, ascending: true)
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(label)
                    .font(DesignTokens.Typography.eyebrow)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if sort?.key == key {
                    Image(systemName: (sort?.ascending ?? true) ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private func row(for record: BaseRecord) -> some View {
        Button {
            onOpenNote(record.note.id)
        } label: {
            HStack(spacing: 0) {
                Text(record.note.title.isEmpty ? "Untitled" : record.note.title)
                    .font(DesignTokens.Typography.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: 220, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.xs)

                ForEach(columns, id: \.self) { key in
                    cell(record.value(forKey: key))
                        .frame(width: 150, alignment: .leading)
                        .padding(.horizontal, DesignTokens.Spacing.xs)
                }
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cell(_ value: PropertyValue?) -> some View {
        switch value {
        case .none:
            Text("—").foregroundStyle(.quaternary)
        case .checkbox(let b):
            Image(systemName: b ? "checkmark.square.fill" : "square")
                .foregroundStyle(b ? Color.accentColor : Color.secondary)
        case .list(let xs):
            HStack(spacing: DesignTokens.Spacing.xxs) {
                ForEach(xs.prefix(3), id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .padding(.horizontal, DesignTokens.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(DesignTokens.Palette.surfaceSunken, in: Capsule())
                }
            }
        case .select(let s):
            Text(s)
                .font(.caption)
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.vertical, 1)
                .background(DesignTokens.Palette.surfaceSunken, in: Capsule())
        case .some(let v):
            Text(v.displayString)
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview("Base Table") {
    BaseTableView(
        records: BasePreviewData.records,
        columns: ["status", "priority", "due", "starred"],
        sort: .constant(BaseSort(key: "priority", ascending: true)),
        onOpenNote: { print("open \($0)") }
    )
    .frame(width: 700, height: 360)
}
