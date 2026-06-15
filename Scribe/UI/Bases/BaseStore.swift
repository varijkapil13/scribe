import Foundation

/// Query layer for the Bases feature: load every note in the vault as a
/// ``BaseRecord`` (note metadata + typed frontmatter properties), then filter,
/// sort, and group across them by property — the cross-note "database view"
/// that gives the feature its name.
///
/// The *logic* (``BaseQuery/apply(to:)`` and friends) is pure and value-typed
/// so it can be unit-tested without any database or filesystem. ``BaseStore``
/// is the thin loader that bridges to `NoteStore` + `NoteFileStore`.

// MARK: - Record

/// A single note projected into the Bases world: its `Note` metadata plus the
/// typed properties parsed from its frontmatter `extra` map.
struct BaseRecord: Identifiable, Equatable, Sendable {
    let note: Note
    let properties: [NoteProperty]

    var id: String { note.id }

    init(note: Note, properties: [NoteProperty]) {
        self.note = note
        self.properties = properties
    }

    /// Typed value for `key`, preferring an explicit user property and
    /// falling back to built-in note fields so `title` / `tags` / `created`
    /// are filterable/sortable columns alongside frontmatter properties.
    func value(forKey key: String) -> PropertyValue? {
        if let property = properties.first(where: { $0.key == key }) {
            return property.value
        }
        switch key {
        case "title":   return .text(note.title)
        case "created": return .date(note.createdAt)
        case "updated": return .date(note.updatedAt)
        case "notebookId":
            return note.notebookId.map { .text($0) }
        default:        return nil
        }
    }
}

// MARK: - Filtering

/// Comparison operators a filter clause can use. Applicability depends on the
/// value's type but the engine degrades gracefully (a `.greaterThan` against
/// text compares lexically).
enum FilterOperator: String, CaseIterable, Codable, Hashable, Sendable {
    case equals
    case notEquals
    case contains
    case notContains
    case greaterThan
    case lessThan
    case isEmpty
    case isNotEmpty
    case isTrue        // checkbox
    case isFalse       // checkbox

    var displayName: String {
        switch self {
        case .equals:      return "is"
        case .notEquals:   return "is not"
        case .contains:    return "contains"
        case .notContains: return "does not contain"
        case .greaterThan: return "greater than"
        case .lessThan:    return "less than"
        case .isEmpty:     return "is empty"
        case .isNotEmpty:  return "is not empty"
        case .isTrue:      return "is checked"
        case .isFalse:     return "is unchecked"
        }
    }

    /// Operators that don't read the `operand` (unary predicates).
    var isUnary: Bool {
        switch self {
        case .isEmpty, .isNotEmpty, .isTrue, .isFalse: return true
        default: return false
        }
    }
}

/// A single filter clause: "property `key` `op` `operand`".
struct FilterClause: Identifiable, Equatable, Codable, Hashable, Sendable {
    var id: UUID
    var key: String
    var op: FilterOperator
    /// Text operand, ignored for unary operators. Compared after typed
    /// coercion against the record's value.
    var operand: String

    init(id: UUID = UUID(), key: String, op: FilterOperator, operand: String = "") {
        self.id = id
        self.key = key
        self.op = op
        self.operand = operand
    }

    /// Evaluate this clause against a record.
    func matches(_ record: BaseRecord) -> Bool {
        let value = record.value(forKey: key)

        switch op {
        case .isEmpty:
            return value?.isEmpty ?? true
        case .isNotEmpty:
            return !(value?.isEmpty ?? true)
        case .isTrue:
            if case .checkbox(let b) = value { return b }
            return false
        case .isFalse:
            if case .checkbox(let b) = value { return !b }
            return true
        default:
            break
        }

        guard let value else { return op == .notEquals || op == .notContains }
        let lhs = Self.comparable(value)
        let rhs = operand.trimmingCharacters(in: .whitespaces).lowercased()

        switch op {
        case .equals:      return lhs == rhs
        case .notEquals:   return lhs != rhs
        case .contains:    return lhs.contains(rhs)
        case .notContains: return !lhs.contains(rhs)
        case .greaterThan: return Self.compare(value, operand) == .orderedDescending
        case .lessThan:    return Self.compare(value, operand) == .orderedAscending
        case .isEmpty, .isNotEmpty, .isTrue, .isFalse:
            return false // handled above
        }
    }

    /// Lowercased flat string used for equality / substring matching.
    private static func comparable(_ value: PropertyValue) -> String {
        switch value {
        case .text(let s), .select(let s): return s.lowercased()
        case .number(let n): return PropertyCodec.encodeNumber(n)
        case .checkbox(let b): return b ? "true" : "false"
        case .date(let d): return PropertyCodec.dateFormatter.string(from: d)
        case .list(let xs): return xs.joined(separator: ",").lowercased()
        }
    }

    /// Type-aware ordering of a value against a raw operand (numbers compare
    /// numerically, dates chronologically, everything else lexically).
    static func compare(_ value: PropertyValue, _ operand: String) -> ComparisonResult {
        switch value {
        case .number(let n):
            let rhs = Double(operand.trimmingCharacters(in: .whitespaces)) ?? 0
            if n == rhs { return .orderedSame }
            return n < rhs ? .orderedAscending : .orderedDescending
        case .date(let d):
            guard let rhs = PropertyCodec.parseFlexibleDate(operand.trimmingCharacters(in: .whitespaces)) else {
                return .orderedSame
            }
            if d == rhs { return .orderedSame }
            return d < rhs ? .orderedAscending : .orderedDescending
        default:
            let lhs = comparable(value)
            let rhs = operand.trimmingCharacters(in: .whitespaces).lowercased()
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }
}

// MARK: - Sorting

struct BaseSort: Equatable, Codable, Hashable, Sendable {
    var key: String
    var ascending: Bool

    init(key: String, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

// MARK: - Query

/// A complete, codable Base query: filters (all must match — AND semantics),
/// a sort, and an optional group-by key for the board view.
struct BaseQuery: Equatable, Codable, Hashable, Sendable {
    var filters: [FilterClause]
    var sort: BaseSort?
    /// Property key board columns / card sections group by. Typically a
    /// `select` property such as `status`.
    var groupBy: String?

    init(filters: [FilterClause] = [], sort: BaseSort? = nil, groupBy: String? = nil) {
        self.filters = filters
        self.sort = sort
        self.groupBy = groupBy
    }

    /// Apply filters then sort, returning the resulting ordered records.
    func apply(to records: [BaseRecord]) -> [BaseRecord] {
        let filtered = records.filter { record in
            filters.allSatisfy { $0.matches(record) }
        }
        guard let sort else { return filtered }
        return Self.sorted(filtered, by: sort)
    }

    static func sorted(_ records: [BaseRecord], by sort: BaseSort) -> [BaseRecord] {
        records.sorted { a, b in
            let va = a.value(forKey: sort.key)
            let vb = b.value(forKey: sort.key)

            // Records missing the sort key always sink to the bottom, in BOTH
            // directions — only present-vs-present comparisons honor `ascending`.
            switch (va, vb) {
            case (nil, nil):
                return tiebreak(a, b, ascending: sort.ascending)
            case (nil, _):
                return false        // a missing → a after b
            case (_, nil):
                return true         // b missing → a before b
            case (let va?, let vb?):
                switch compareValues(va, vb) {
                case .orderedSame:       return tiebreak(a, b, ascending: sort.ascending)
                case .orderedAscending:  return sort.ascending
                case .orderedDescending: return !sort.ascending
                }
            }
        }
    }

    /// Deterministic, direction-aware tiebreak on title so equal keys keep a
    /// stable order.
    private static func tiebreak(_ a: BaseRecord, _ b: BaseRecord, ascending: Bool) -> Bool {
        let ta = a.note.title.lowercased()
        let tb = b.note.title.lowercased()
        if ta == tb { return false }
        return ascending ? ta < tb : tb < ta
    }

    /// Type-aware ordering of two typed values.
    static func compareValues(_ a: PropertyValue, _ b: PropertyValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            if x == y { return .orderedSame }
            return x < y ? .orderedAscending : .orderedDescending
        case (.date(let x), .date(let y)):
            if x == y { return .orderedSame }
            return x < y ? .orderedAscending : .orderedDescending
        case (.checkbox(let x), .checkbox(let y)):
            if x == y { return .orderedSame }
            return (!x && y) ? .orderedAscending : .orderedDescending
        default:
            let sx = a.sortKey
            let sy = b.sortKey
            if sx == sy { return .orderedSame }
            return sx < sy ? .orderedAscending : .orderedDescending
        }
    }

    /// Group records by the `groupBy` key (or a single `nil` group when no
    /// key is set). Returns groups in a deterministic order: option values
    /// sorted alphabetically, with the "no value" group last.
    func grouped(_ records: [BaseRecord]) -> [BaseGroup] {
        let applied = apply(to: records)
        guard let groupBy else {
            return [BaseGroup(key: nil, records: applied)]
        }
        var buckets: [String: [BaseRecord]] = [:]
        var noValue: [BaseRecord] = []
        for record in applied {
            if let value = record.value(forKey: groupBy), !value.isEmpty {
                buckets[value.groupKey, default: []].append(record)
            } else {
                noValue.append(record)
            }
        }
        var groups = buckets.keys.sorted().map { key in
            BaseGroup(key: key, records: buckets[key] ?? [])
        }
        if !noValue.isEmpty {
            groups.append(BaseGroup(key: nil, records: noValue))
        }
        return groups
    }
}

/// One column / section of a grouped Base view.
struct BaseGroup: Identifiable, Equatable, Sendable {
    /// The shared group value, or nil for the "no value" bucket.
    let key: String?
    let records: [BaseRecord]

    var id: String { key ?? "\u{0000}__none__" }
    var title: String { key ?? "No value" }
}

private extension PropertyValue {
    /// Lexical sort key for non-numeric/date comparisons.
    var sortKey: String {
        switch self {
        case .text(let s), .select(let s): return s.lowercased()
        case .number(let n): return String(format: "%020.6f", n)
        case .checkbox(let b): return b ? "1" : "0"
        case .date(let d): return PropertyCodec.dateFormatter.string(from: d)
        case .list(let xs): return xs.joined(separator: ",").lowercased()
        }
    }

    /// Bucket key for grouping (single value; a list groups by its first
    /// element so a multi-tag note lands in one column).
    var groupKey: String {
        switch self {
        case .text(let s), .select(let s): return s
        case .number(let n): return PropertyCodec.encodeNumber(n)
        case .checkbox(let b): return b ? "true" : "false"
        case .date(let d): return PropertyCodec.dateFormatter.string(from: d)
        case .list(let xs): return xs.first ?? ""
        }
    }
}

// MARK: - Column discovery

extension Array where Element == BaseRecord {
    /// Distinct property keys present across these records, in first-seen
    /// order, with the most common keys prioritized. Drives the default set
    /// of table columns and the filter/group key pickers.
    func discoveredPropertyKeys() -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for record in self {
            for property in record.properties where !seen.contains(property.key) {
                seen.insert(property.key)
                ordered.append(property.key)
            }
        }
        return ordered
    }

    /// Distinct non-empty option values for a `select`/text key, sorted —
    /// used to seed board columns and select pickers.
    func distinctValues(forKey key: String) -> [String] {
        var seen: Set<String> = []
        for record in self {
            if let value = record.value(forKey: key), !value.isEmpty {
                switch value {
                case .list(let xs): xs.forEach { seen.insert($0) }
                case .text(let s), .select(let s): seen.insert(s)
                case .number(let n): seen.insert(PropertyCodec.encodeNumber(n))
                case .checkbox(let b): seen.insert(b ? "true" : "false")
                case .date(let d): seen.insert(PropertyCodec.dateFormatter.string(from: d))
                }
            }
        }
        return seen.sorted()
    }
}

// MARK: - Store

/// Loads vault notes as ``BaseRecord``s for the Bases views. Reads run on the
/// caller's thread off `NoteStore`; the heavy frontmatter parse is per-note
/// and best-effort (a note whose file can't be read still appears, with just
/// its DB metadata as properties).
final class BaseStore: @unchecked Sendable {

    private let noteStore: NoteStore

    nonisolated static let shared = BaseStore(noteStore: .shared)

    init(noteStore: NoteStore = .shared) {
        self.noteStore = noteStore
    }

    /// Load every note in the vault projected into Bases records. Properties
    /// come from each note's frontmatter `extra` map; notes with no file on
    /// disk (or none readable) contribute an empty property list.
    func loadRecords(typeHints: [String: PropertyType] = [:]) throws -> [BaseRecord] {
        let notes = try noteStore.fetchAllNotes()
        let fileStore = noteStore.fileStore
        return notes.map { note in
            var properties: [NoteProperty] = []
            if let fileStore,
               let url = try? fileStore.findURL(for: note.id),
               let file = try? fileStore.read(at: url) {
                properties = file.frontmatter.properties(typeHints: typeHints)
            }
            return BaseRecord(note: note, properties: properties)
        }
    }

    /// Persist an edited property set back to a note's frontmatter file,
    /// preserving body + reserved extras. No-op when no file store is
    /// configured (logic-only contexts).
    func saveProperties(_ properties: [NoteProperty], forNoteId id: String) throws {
        guard let fileStore = noteStore.fileStore,
              let url = try fileStore.findURL(for: id),
              var file = try? fileStore.read(at: url) else { return }
        file.frontmatter.applyProperties(properties)
        VaultWriteGuard.shared.recordSelfWrite()
        try fileStore.write(file)
    }
}
