import SwiftUI

/// Host screen for the Bases feature. Loads vault notes as records, shows the
/// filter / sort / group controls, a layout switcher, and the table / board /
/// card view for the current layout. Reloads when notes change.
///
/// Mirrors the surrounding detail-pane convention: an `onNavigate` closure
/// lets it hand a note id back to the `NavigationCoordinator` so opening a row
/// behaves like every other navigation in the app.
struct BasesScreen: View {

    var onNavigate: (String) -> Void

    @State private var model = BasesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            BaseFilterControls(
                query: $model.query,
                availableKeys: model.availableKeys,
                valuesProvider: { model.distinctValues(forKey: $0) }
            )
            Divider()
            content
        }
        .navigationTitle("Bases")
        .onAppear { model.reload() }
        .onReceive(NoteStore.shared.observeNotes().replaceError(with: [])) { _ in
            model.reload()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Bases")
                    .font(DesignTokens.Typography.title2)
                Text("\(model.filteredRecords.count) of \(model.records.count) notes")
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Layout", selection: $model.layout) {
                ForEach(BasesViewModel.Layout.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(DesignTokens.Spacing.md)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            ContentUnavailableView(
                "Couldn't load notes",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if model.records.isEmpty {
            ContentUnavailableView(
                "No notes yet",
                systemImage: "tablecells",
                description: Text("Notes with frontmatter properties will appear here.")
            )
        } else {
            switch model.layout {
            case .table:
                BaseTableView(
                    records: model.filteredRecords,
                    columns: tableColumns,
                    sort: $model.query.sort,
                    onOpenNote: onNavigate
                )
            case .board:
                BaseBoardView(
                    groups: model.groups,
                    groupBy: model.query.groupBy,
                    summaryKeys: Array(model.defaultColumns.prefix(3)),
                    onOpenNote: onNavigate
                )
            case .card:
                BaseCardView(
                    records: model.filteredRecords,
                    chipKeys: Array(model.defaultColumns.prefix(4)),
                    onOpenNote: onNavigate
                )
            }
        }
    }

    /// Columns shown in the table: the user-discovered keys, defaulting to a
    /// capped set when nothing is otherwise configured.
    private var tableColumns: [String] {
        let cols = model.defaultColumns
        return cols.isEmpty ? ["created"] : cols
    }
}

#Preview("Bases Screen") {
    BasesScreen(onNavigate: { print("open \($0)") })
        .frame(width: 820, height: 560)
}
