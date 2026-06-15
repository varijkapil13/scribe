import SwiftUI

/// View-model backing the Bases screen: loads records from ``BaseStore``,
/// holds the live ``BaseQuery`` (filters / sort / group-by) and the chosen
/// layout, and exposes derived collections the three views render.
///
/// Lives on the main actor (it drives SwiftUI state); the heavy query logic it
/// delegates to is pure and unit-tested separately in `BaseStore`.
@MainActor
@Observable
final class BasesViewModel {

    /// Which layout the Bases host currently shows.
    enum Layout: String, CaseIterable, Identifiable, Sendable {
        case table, board, card
        var id: String { rawValue }
        var title: String {
            switch self {
            case .table: return "Table"
            case .board: return "Board"
            case .card:  return "Cards"
            }
        }
        var systemImage: String {
            switch self {
            case .table: return "tablecells"
            case .board: return "rectangle.split.3x1"
            case .card:  return "square.grid.2x2"
            }
        }
    }

    private let store: BaseStore
    private let definitionStore: BaseDefinitionStore

    private(set) var records: [BaseRecord] = []
    var query = BaseQuery()
    var layout: Layout = .table
    var loadError: String?

    // MARK: - Saved base definitions

    /// All persisted base definitions, newest list refreshed from disk.
    private(set) var definitions: [BaseDefinition] = []
    /// The currently-active base's id, if one is selected.
    private(set) var activeBaseId: UUID?
    /// User-chosen visible columns for the active base ([] = store defaults).
    private var savedColumns: [String] = []
    /// Suppresses persistence while we mutate `query`/`layout` programmatically
    /// (e.g. when loading a base) so we don't write back what we just read.
    private var isApplyingDefinition = false

    init(store: BaseStore = .shared, definitionStore: BaseDefinitionStore = .shared) {
        self.store = store
        self.definitionStore = definitionStore
    }

    /// Reload every vault note as a Base record. Cheap enough to call on
    /// appear / when notes change.
    func reload() {
        do {
            records = try store.loadRecords()
            loadError = nil
        } catch {
            records = []
            loadError = error.localizedDescription
        }
    }

    var activeBase: BaseDefinition? {
        guard let activeBaseId else { return nil }
        return definitions.first { $0.id == activeBaseId }
    }

    /// Load the list of saved definitions and activate one (the previously
    /// active base if it still exists, else the first). Call on appear.
    func loadDefinitions() {
        definitions = (try? definitionStore.list()) ?? []
        if let activeBaseId, definitions.contains(where: { $0.id == activeBaseId }) {
            // keep current selection
        } else if let first = definitions.first {
            activate(first.id)
        } else {
            activeBaseId = nil
        }
    }

    /// Make `id` the active base, applying its query / layout / columns to the
    /// live state without persisting back.
    func activate(_ id: UUID) {
        guard let definition = definitions.first(where: { $0.id == id }) else { return }
        activeBaseId = id
        isApplyingDefinition = true
        query = definition.query
        layout = Layout(definition.layout)
        savedColumns = definition.columns
        isApplyingDefinition = false
    }

    /// Create a new base, persist it, refresh the list, and make it active.
    @discardableResult
    func createBase(name: String) -> BaseDefinition? {
        guard let created = try? definitionStore.create(name: name) else { return nil }
        definitions = (try? definitionStore.list()) ?? definitions
        activate(created.id)
        return created
    }

    /// Rename the active base (or a given one) and refresh the list.
    func renameActiveBase(to name: String) {
        guard let id = activeBaseId else { return }
        _ = try? definitionStore.rename(id: id, to: name)
        definitions = (try? definitionStore.list()) ?? definitions
    }

    /// Delete a base; if it was active, fall back to another (or none).
    func deleteBase(id: UUID) {
        try? definitionStore.delete(id: id)
        definitions = (try? definitionStore.list()) ?? []
        if activeBaseId == id {
            if let next = definitions.first {
                activate(next.id)
            } else {
                activeBaseId = nil
                isApplyingDefinition = true
                query = BaseQuery()
                layout = .table
                savedColumns = []
                isApplyingDefinition = false
            }
        }
    }

    /// Persist the active base's current query / layout / columns back to disk.
    /// Called after the user edits filters, sort, grouping, layout, or columns.
    func persistActiveBase() {
        guard !isApplyingDefinition, let id = activeBaseId,
              var definition = definitions.first(where: { $0.id == id }) else { return }
        definition.query = query
        definition.layout = BaseDefinition.Layout(layout)
        definition.columns = savedColumns
        if (try? definitionStore.save(definition)) != nil {
            definitions = (try? definitionStore.list()) ?? definitions
        }
    }

    // MARK: - Derived collections

    /// Filtered + sorted records for the table/card views.
    var filteredRecords: [BaseRecord] {
        query.apply(to: records)
    }

    /// Grouped records for the board view (by `query.groupBy`).
    var groups: [BaseGroup] {
        query.grouped(records)
    }

    /// Property keys discovered across the vault — the candidate columns,
    /// filter keys, and group keys. Built-in `title`/`created`/`updated` are
    /// offered first so they're always available.
    var availableKeys: [String] {
        ["title", "created", "updated"] + records.discoveredPropertyKeys()
    }

    /// Default visible table columns: the most useful discovered properties
    /// (capped) so the table isn't overwhelming on a large vault.
    var defaultColumns: [String] {
        Array(records.discoveredPropertyKeys().prefix(6))
    }

    /// Columns the active base shows: the user's saved selection, or the
    /// discovered defaults when none has been pinned.
    var visibleColumns: [String] {
        savedColumns.isEmpty ? defaultColumns : savedColumns
    }

    /// Toggle a property column's visibility in the active base and persist.
    func toggleColumn(_ key: String) {
        var cols = visibleColumns
        if let idx = cols.firstIndex(of: key) {
            cols.remove(at: idx)
        } else {
            cols.append(key)
        }
        savedColumns = cols
        persistActiveBase()
    }

    func isColumnVisible(_ key: String) -> Bool {
        visibleColumns.contains(key)
    }

    func distinctValues(forKey key: String) -> [String] {
        records.distinctValues(forKey: key)
    }

    // MARK: - Query mutations

    func addFilter() {
        let key = availableKeys.first ?? "title"
        query.filters.append(FilterClause(key: key, op: .contains))
        persistActiveBase()
    }

    func removeFilter(_ clause: FilterClause) {
        query.filters.removeAll { $0.id == clause.id }
        persistActiveBase()
    }

    func toggleSort(key: String) {
        if query.sort?.key == key {
            query.sort?.ascending.toggle()
        } else {
            query.sort = BaseSort(key: key, ascending: true)
        }
        persistActiveBase()
    }
}

// MARK: - Layout <-> persisted layout mapping

extension BasesViewModel.Layout {
    init(_ persisted: BaseDefinition.Layout) {
        switch persisted {
        case .table: self = .table
        case .board: self = .board
        case .card:  self = .card
        }
    }
}

extension BaseDefinition.Layout {
    init(_ layout: BasesViewModel.Layout) {
        switch layout {
        case .table: self = .table
        case .board: self = .board
        case .card:  self = .card
        }
    }
}
