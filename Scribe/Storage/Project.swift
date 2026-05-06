import Foundation
import GRDB

/// A grouping container for tasks (e.g. "Work", "Personal", "Side project").
struct Project: Codable, Identifiable, Equatable, Hashable {

    var id: String
    var name: String
    /// Hex string (e.g. "#FF8800") — UI maps this to a `Color`.
    var color: String?
    /// SF Symbol name.
    var icon: String?
    var createdAt: Date
    /// Manual ordering for the sidebar list.
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        color: String? = nil,
        icon: String? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }
}

extension Project: FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects"
}
