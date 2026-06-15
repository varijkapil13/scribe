import SwiftUI

/// Reusable filter / sort / group control strip shared by the table, board,
/// and card Base views. Mutates the bound ``BaseQuery`` in place; the host
/// view-model derives its filtered collections from that query, so edits here
/// reflect live everywhere.
struct BaseFilterControls: View {

    @Binding var query: BaseQuery
    /// Candidate keys for filter / sort / group pickers.
    let availableKeys: [String]
    /// Distinct values per key, for select-style filter operands.
    var valuesProvider: (String) -> [String] = { _ in [] }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                sortControl
                groupControl
                Spacer()
                Button {
                    query.filters.append(FilterClause(key: availableKeys.first ?? "title", op: .contains))
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)
            }

            if !query.filters.isEmpty {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach($query.filters) { $clause in
                        FilterClauseRow(
                            clause: $clause,
                            availableKeys: availableKeys,
                            suggestions: valuesProvider(clause.key),
                            onRemove: { query.filters.removeAll { $0.id == clause.id } }
                        )
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceElevated)
    }

    // MARK: - Sort

    private var sortControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Menu {
                Button("None") { query.sort = nil }
                Divider()
                ForEach(availableKeys, id: \.self) { key in
                    Button(key) {
                        query.sort = SortDescriptor(key: key, ascending: query.sort?.ascending ?? true)
                    }
                }
            } label: {
                Label(query.sort.map { "Sort: \($0.key)" } ?? "Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if query.sort != nil {
                Button {
                    query.sort?.ascending.toggle()
                } label: {
                    Image(systemName: (query.sort?.ascending ?? true) ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Toggle direction")
            }
        }
    }

    // MARK: - Group

    private var groupControl: some View {
        Menu {
            Button("None") { query.groupBy = nil }
            Divider()
            ForEach(availableKeys, id: \.self) { key in
                Button(key) { query.groupBy = key }
            }
        } label: {
            Label(query.groupBy.map { "Group: \($0)" } ?? "Group", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Filter clause row

private struct FilterClauseRow: View {
    @Binding var clause: FilterClause
    let availableKeys: [String]
    var suggestions: [String]
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Picker("Key", selection: $clause.key) {
                ForEach(availableKeys, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("Operator", selection: $clause.op) {
                ForEach(FilterOperator.allCases, id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            if !clause.op.isUnary {
                if suggestions.isEmpty {
                    TextField("value", text: $clause.operand)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                } else {
                    Picker("Value", selection: $clause.operand) {
                        Text("Any").tag("")
                        ForEach(suggestions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Shared value formatting

extension PropertyValue {
    /// Human-friendly display string for a value in cells / cards / badges.
    var displayString: String {
        switch self {
        case .text(let s), .select(let s): return s
        case .number(let n): return PropertyCodec.encodeNumber(n)
        case .checkbox(let b): return b ? "✓" : "✗"
        case .date(let d): return PropertyCodec.dateFormatter.string(from: d)
        case .list(let xs): return xs.joined(separator: ", ")
        }
    }
}
