import Foundation

/// Typed, structured view of a note's frontmatter metadata.
///
/// Scribe's `NoteFrontmatterCodec` round-trips known keys with typed fields
/// and preserves every *other* key verbatim in `NoteFrontmatter.extra` as an
/// already-encoded string. The Bases feature layers a *typed* property model
/// over that `extra` map: a `status: doing` line becomes a
/// ``NoteProperty`` with a `.select` value, a `due: 2026-06-15` line becomes
/// a `.date`, and so on.
///
/// The model is deliberately **pure and value-typed** so it is trivially
/// testable and carries no SwiftUI / storage dependency. Parsing and
/// serialization are symmetric with the codec's own scalar/list conventions
/// so a property edited here round-trips losslessly through the `.md` file.
///
/// Type inference is *heuristic* on read (the wire format is untyped YAML),
/// but a saved Base view can pin a column to an explicit ``PropertyType`` so
/// the same key renders consistently across notes.

// MARK: - Property type

/// The set of value shapes a note property can take. Mirrors Obsidian's
/// property types. `select` is a single-choice string (kanban/group column);
/// `list` is a multi-value string array.
enum PropertyType: String, CaseIterable, Codable, Hashable, Sendable {
    case text
    case number
    case date
    case checkbox
    case list
    case select

    var displayName: String {
        switch self {
        case .text:     return "Text"
        case .number:   return "Number"
        case .date:     return "Date"
        case .checkbox: return "Checkbox"
        case .list:     return "List"
        case .select:   return "Select"
        }
    }

    /// SF Symbol used to badge the type in property editors / column headers.
    var systemImage: String {
        switch self {
        case .text:     return "textformat"
        case .number:   return "number"
        case .date:     return "calendar"
        case .checkbox: return "checkmark.square"
        case .list:     return "list.bullet"
        case .select:   return "tag"
        }
    }
}

// MARK: - Property value

/// A typed frontmatter value. The associated payloads are normalized
/// in-memory shapes (a real `Date`, a `Double`, a `[String]`); the wire
/// encoding lives in ``PropertyValue/encoded`` and ``PropertyValue/parse``.
enum PropertyValue: Equatable, Hashable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    case checkbox(Bool)
    case list([String])
    /// A single chosen option (the kanban / group key).
    case select(String)

    var type: PropertyType {
        switch self {
        case .text:     return .text
        case .number:   return .number
        case .date:     return .date
        case .checkbox: return .checkbox
        case .list:     return .list
        case .select:   return .select
        }
    }

    /// True when the value carries no meaningful content (empty string /
    /// empty list). Used to decide whether a property should be emitted to
    /// frontmatter at all — empty values are dropped, matching the codec's
    /// "don't write blank extras" policy.
    var isEmpty: Bool {
        switch self {
        case .text(let s):   return s.trimmingCharacters(in: .whitespaces).isEmpty
        case .select(let s): return s.trimmingCharacters(in: .whitespaces).isEmpty
        case .list(let xs):  return xs.isEmpty
        case .number, .date, .checkbox: return false
        }
    }
}

// MARK: - Note property

/// A single typed key/value pair belonging to a note's frontmatter.
struct NoteProperty: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identity for SwiftUI lists — the frontmatter key is unique
    /// within a note, so it doubles as the id.
    var id: String { key }
    var key: String
    var value: PropertyValue

    init(key: String, value: PropertyValue) {
        self.key = key
        self.value = value
    }

    var type: PropertyType { value.type }
}

// MARK: - Parsing & serialization

extension PropertyValue {

    /// Wire encoding for this value, symmetric with ``PropertyValue/parse``
    /// and compatible with the frontmatter codec's scalar/list conventions.
    /// Stored back into `NoteFrontmatter.extra` verbatim.
    var encoded: String {
        switch self {
        case .text(let s):   return PropertyCodec.encodeScalar(s)
        case .select(let s): return PropertyCodec.encodeScalar(s)
        case .number(let n): return PropertyCodec.encodeNumber(n)
        case .checkbox(let b): return b ? "true" : "false"
        case .date(let d):   return PropertyCodec.dateFormatter.string(from: d)
        case .list(let xs):  return PropertyCodec.encodeList(xs)
        }
    }

    /// Parse an untyped frontmatter value into a typed value, *coercing* to
    /// the requested type when one is supplied (e.g. a saved Base column
    /// pins a key to `.date`). When `as` is nil, the type is inferred
    /// heuristically from the raw text.
    static func parse(_ raw: String, as type: PropertyType? = nil) -> PropertyValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        guard let type else { return inferred(from: trimmed) }

        switch type {
        case .text:
            return .text(PropertyCodec.decodeScalar(trimmed))
        case .select:
            return .select(PropertyCodec.decodeScalar(trimmed))
        case .number:
            return .number(Double(trimmed) ?? 0)
        case .checkbox:
            return .checkbox(trimmed.lowercased() == "true")
        case .date:
            return .date(PropertyCodec.dateFormatter.date(from: trimmed)
                ?? PropertyCodec.parseFlexibleDate(trimmed)
                ?? Date(timeIntervalSince1970: 0))
        case .list:
            return .list(PropertyCodec.decodeList(trimmed))
        }
    }

    /// Best-effort type inference for an untyped value. Order matters:
    /// list (bracketed) → checkbox → number → date → text.
    private static func inferred(from trimmed: String) -> PropertyValue {
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return .list(PropertyCodec.decodeList(trimmed))
        }
        let lower = trimmed.lowercased()
        if lower == "true" || lower == "false" {
            return .checkbox(lower == "true")
        }
        if let n = Double(trimmed), !trimmed.isEmpty {
            return .number(n)
        }
        if let d = PropertyCodec.parseFlexibleDate(trimmed) {
            return .date(d)
        }
        return .text(PropertyCodec.decodeScalar(trimmed))
    }
}

// MARK: - Codec helpers

/// Low-level scalar/list/number/date encoding shared by ``PropertyValue``.
/// Mirrors the conventions in `NoteFrontmatterCodec` (bracketed comma-joined
/// lists, quoted scalars when they contain structural characters) so values
/// written here parse cleanly when the codec re-reads them — and vice versa.
enum PropertyCodec {

    static func encodeScalar(_ s: String) -> String {
        let needsQuotes = s.contains(",")
            || s.contains(":")
            || s.contains("#")
            || s.contains("\"")
            || s.contains("[") || s.contains("]")
            || s != s.trimmingCharacters(in: .whitespaces)
        guard needsQuotes else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func decodeScalar(_ s: String) -> String {
        guard s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 else { return s }
        let inner = String(s.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func encodeList(_ xs: [String]) -> String {
        guard !xs.isEmpty else { return "[]" }
        return "[\(xs.map(encodeScalar).joined(separator: ", "))]"
    }

    static func decodeList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
            // A bare scalar coerced to a list becomes a single-element list.
            let scalar = decodeScalar(trimmed)
            return scalar.isEmpty ? [] : [scalar]
        }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map(decodeScalar)
            .filter { !$0.isEmpty }
    }

    /// Numbers render without a trailing `.0` when integral so the file
    /// stays human-friendly (`count: 3`, not `count: 3.0`).
    static func encodeNumber(_ n: Double) -> String {
        if n.rounded() == n && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }

    /// `yyyy-MM-dd` in UTC — same convention as the codec's `dailyDate`.
    nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Accepts either a bare `yyyy-MM-dd` date or a full ISO-8601 timestamp.
    static func parseFlexibleDate(_ s: String) -> Date? {
        if let d = dateFormatter.date(from: s) { return d }
        return isoFormatter.date(from: s)
    }
}

// MARK: - Frontmatter bridge

extension NoteFrontmatter {

    /// Frontmatter keys the typed-property model never surfaces, because the
    /// codec already models them with first-class fields (or they are
    /// internal). Editing those goes through the note's own UI, not the
    /// generic property pane.
    static let reservedPropertyKeys: Set<String> = [
        "id", "title", "created", "updated", "notebookId", "tags",
        "isDailyNote", "dailyDate", "font", "cover", "icon",
    ]

    /// The note's user-defined typed properties, derived from `extra`,
    /// in file order. Reserved keys are skipped.
    ///
    /// - Parameter typeHints: optional per-key type pins (from a saved Base
    ///   column) so a key renders as the same type across notes.
    func properties(typeHints: [String: PropertyType] = [:]) -> [NoteProperty] {
        extra.compactMap { entry in
            guard !Self.reservedPropertyKeys.contains(entry.key) else { return nil }
            let value = PropertyValue.parse(entry.value, as: typeHints[entry.key])
            return NoteProperty(key: entry.key, value: value)
        }
    }

    /// Reads a single typed property by key, if present (and not reserved).
    func property(forKey key: String, as type: PropertyType? = nil) -> PropertyValue? {
        guard !Self.reservedPropertyKeys.contains(key),
              let raw = extraValue(forKey: key) else { return nil }
        return PropertyValue.parse(raw, as: type)
    }

    /// Writes a typed property back into `extra` (encoded verbatim). An
    /// empty value removes the key, matching the codec's "no blank extras"
    /// policy. Reserved keys are ignored.
    mutating func setProperty(_ key: String, _ value: PropertyValue?) {
        guard !Self.reservedPropertyKeys.contains(key) else { return }
        if let value, !value.isEmpty {
            setExtra(key, value.encoded)
        } else {
            setExtra(key, nil)
        }
    }

    /// Bulk-applies a property list, replacing every existing user property
    /// while preserving reserved extras (font/cover/icon) and order of
    /// remaining keys. New keys are appended in `properties` order.
    mutating func applyProperties(_ properties: [NoteProperty]) {
        // Keep reserved extras (font/cover/icon) as-is, then re-add the
        // user properties from the model.
        let reserved = extra.filter { Self.reservedPropertyKeys.contains($0.key) }
        var rebuilt = reserved
        for property in properties
        where !property.value.isEmpty && !Self.reservedPropertyKeys.contains(property.key) {
            rebuilt.removeAll { $0.key == property.key }
            rebuilt.append(FrontmatterEntry(key: property.key, value: property.value.encoded))
        }
        extra = rebuilt
    }
}
