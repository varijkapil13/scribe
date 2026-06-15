import Foundation

/// A persisted "base": a named, saved view over the vault's notes. It bundles
/// the live ``BaseQuery`` (filters / sort / group-by) with presentation state
/// — which layout to show and which property columns are visible — so the
/// whole configuration round-trips to disk and drives ``BaseStore`` queries on
/// reopen.
///
/// The model is **pure, value-typed, and Codable** with no SwiftUI / storage
/// dependency, so it is trivially testable and persists as a plain JSON file
/// (see ``BaseDefinitionStore``). It reuses the already-Codable `BaseQuery`,
/// `FilterClause`, and `BaseSort` from `BaseStore.swift` so the on-disk shape
/// stays in lockstep with the query engine.
struct BaseDefinition: Identifiable, Equatable, Codable, Hashable, Sendable {

    /// Which Bases layout a saved definition opens in. Mirrors
    /// `BasesViewModel.Layout` but lives on the model so it persists; the
    /// view-model maps between the two.
    enum Layout: String, CaseIterable, Codable, Sendable {
        case table
        case board
        case card
    }

    /// Stable identity, also used as the on-disk file name (`<id>.json`).
    var id: UUID
    /// User-facing name shown in the base picker.
    var name: String
    /// The saved query: filters, sort, and group-by.
    var query: BaseQuery
    /// Which layout the base opens in.
    var layout: Layout
    /// Visible property columns (in display order) for the table view. Empty
    /// means "use the store's discovered defaults".
    var columns: [String]
    /// Creation / last-modified timestamps, for stable list ordering and
    /// future "recently edited" surfaces.
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        query: BaseQuery = BaseQuery(),
        layout: Layout = .table,
        columns: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.layout = layout
        self.columns = columns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Tolerate older / partial JSON: every field except id+name has a default
    // so a hand-edited or future-truncated file still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Base"
        self.query = try c.decodeIfPresent(BaseQuery.self, forKey: .query) ?? BaseQuery()
        self.layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .table
        self.columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt
    }
}
