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
    @State private var showNewBaseSheet = false
    @State private var showRenameSheet = false
    @State private var pendingName = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.activeBase != nil {
                BaseFilterControls(
                    query: $model.query,
                    availableKeys: model.availableKeys,
                    valuesProvider: { model.distinctValues(forKey: $0) }
                )
                Divider()
            }
            content
        }
        .navigationTitle("Bases")
        .onAppear {
            model.reload()
            model.loadDefinitions()
        }
        .onChange(of: model.query) { _, _ in model.persistActiveBase() }
        .onChange(of: model.layout) { _, _ in model.persistActiveBase() }
        .onReceive(NoteStore.shared.observeNotes().replaceError(with: [])) { _ in
            model.reload()
        }
        .sheet(isPresented: $showNewBaseSheet) {
            BaseNameSheet(title: "New Base", name: $pendingName) { name in
                model.createBase(name: name)
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            BaseNameSheet(title: "Rename Base", name: $pendingName) { name in
                model.renameActiveBase(to: name)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                basePicker
                Text("\(model.filteredRecords.count) of \(model.records.count) notes")
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeBase != nil {
                columnsMenu
                Picker("Layout", selection: $model.layout) {
                    ForEach(BasesViewModel.Layout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    /// Base selector + create / rename / delete affordances.
    private var basePicker: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Menu {
                if model.definitions.isEmpty {
                    Text("No bases yet")
                } else {
                    ForEach(model.definitions) { base in
                        Button {
                            model.activate(base.id)
                        } label: {
                            if base.id == model.activeBaseId {
                                Label(base.name, systemImage: "checkmark")
                            } else {
                                Text(base.name)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    pendingName = ""
                    showNewBaseSheet = true
                } label: {
                    Label("New Base", systemImage: "plus")
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(model.activeBase?.name ?? "Bases")
                        .font(DesignTokens.Typography.title2)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if model.activeBase != nil {
                Menu {
                    Button {
                        pendingName = model.activeBase?.name ?? ""
                        showRenameSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if let id = model.activeBaseId {
                        Button(role: .destructive) {
                            model.deleteBase(id: id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    /// Column visibility toggles for the table view.
    private var columnsMenu: some View {
        Menu {
            ForEach(model.availableKeys, id: \.self) { key in
                Button {
                    model.toggleColumn(key)
                } label: {
                    if model.isColumnVisible(key) {
                        Label(key, systemImage: "checkmark")
                    } else {
                        Text(key)
                    }
                }
            }
        } label: {
            Label("Columns", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
        } else if model.activeBase == nil {
            ContentUnavailableView {
                Label("No base selected", systemImage: "tablecells")
            } description: {
                Text("Create a base to filter, sort, and group your notes into a saved view.")
            } actions: {
                Button("New Base") {
                    pendingName = ""
                    showNewBaseSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
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
                    summaryKeys: Array(model.visibleColumns.prefix(3)),
                    onOpenNote: onNavigate
                )
            case .card:
                BaseCardView(
                    records: model.filteredRecords,
                    chipKeys: Array(model.visibleColumns.prefix(4)),
                    onOpenNote: onNavigate
                )
            }
        }
    }

    /// Columns shown in the table: the active base's visible columns,
    /// defaulting to a capped discovered set when nothing is configured.
    private var tableColumns: [String] {
        let cols = model.visibleColumns
        return cols.isEmpty ? ["created"] : cols
    }
}

// MARK: - Name entry sheet

/// Small modal used for both creating and renaming a base.
private struct BaseNameSheet: View {
    let title: String
    @Binding var name: String
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text(title)
                .font(DesignTokens.Typography.title2)
            TextField("Base name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 340)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

#Preview("Bases Screen") {
    BasesScreen(onNavigate: { print("open \($0)") })
        .frame(width: 820, height: 560)
}
