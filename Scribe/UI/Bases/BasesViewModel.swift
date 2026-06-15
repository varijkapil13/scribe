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

    private(set) var records: [BaseRecord] = []
    var query = BaseQuery()
    var layout: Layout = .table
    var loadError: String?

    init(store: BaseStore = .shared) {
        self.store = store
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

    func distinctValues(forKey key: String) -> [String] {
        records.distinctValues(forKey: key)
    }

    // MARK: - Query mutations

    func addFilter() {
        let key = availableKeys.first ?? "title"
        query.filters.append(FilterClause(key: key, op: .contains))
    }

    func removeFilter(_ clause: FilterClause) {
        query.filters.removeAll { $0.id == clause.id }
    }

    func toggleSort(key: String) {
        if query.sort?.key == key {
            query.sort?.ascending.toggle()
        } else {
            query.sort = BaseSort(key: key, ascending: true)
        }
    }
}
