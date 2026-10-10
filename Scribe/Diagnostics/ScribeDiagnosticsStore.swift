import Foundation

/// What a stored diagnostics file holds.
enum ScribeDiagnosticsKind: String, CaseIterable, Sendable {
    /// `MXDiagnosticPayload` — crashes, hangs, CPU / disk-write exceptions.
    case diagnostic
    /// `MXMetricPayload` — the daily performance summary.
    case metric
}

/// One stored payload file, as seen by the rotation logic.
struct ScribeDiagnosticsFile: Equatable, Sendable {
    let name: String
    let kind: ScribeDiagnosticsKind
    let createdAt: Date
}

/// Pure naming + rotation rules for the diagnostics folder (pinned by tests).
enum ScribeDiagnosticsRotation {

    /// At most this many payload files are kept.
    nonisolated static let maxFiles = 20

    nonisolated static let fileExtension = "json"

    /// `2026-10-10T08-15-00Z-diagnostic-1a2b3c4d.json`: sortable by time,
    /// colon-free (Finder-safe), and unique per write.
    nonisolated static func fileName(kind: ScribeDiagnosticsKind, date: Date, uniquifier: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let suffix = uniquifier.isEmpty ? "" : "-" + uniquifier
        return "\(stamp)-\(kind.rawValue)\(suffix).\(fileExtension)"
    }

    /// The kind encoded in a file name, or nil for files Scribe didn't write.
    nonisolated static func kind(ofFileName name: String) -> ScribeDiagnosticsKind? {
        guard name.hasSuffix("." + fileExtension) else { return nil }
        for kind in ScribeDiagnosticsKind.allCases where name.contains("-\(kind.rawValue)") {
            return kind
        }
        return nil
    }

    /// Names to delete so at most `limit` files remain. Daily metric
    /// summaries go first (oldest first), so a burst of them never pushes out
    /// a crash or hang report; then the oldest diagnostics.
    nonisolated static func filesToRemove(_ files: [ScribeDiagnosticsFile], limit: Int = maxFiles) -> [String] {
        let excess = files.count - max(0, limit)
        guard excess > 0 else { return [] }
        let ordered = files.sorted { lhs, rhs in
            let lp = priority(lhs.kind), rp = priority(rhs.kind)
            if lp != rp { return lp < rp }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.name < rhs.name
        }
        return ordered.prefix(excess).map(\.name)
    }

    /// Lower = removed first.
    nonisolated private static func priority(_ kind: ScribeDiagnosticsKind) -> Int {
        switch kind {
        case .metric:     return 0
        case .diagnostic: return 1
        }
    }
}

/// The on-disk diagnostics folder: `~/Library/Application Support/Scribe/
/// Diagnostics`. Payloads stay on this Mac; nothing is ever uploaded. The
/// user can reveal or export them from Settings › About.
struct ScribeDiagnosticsStore: Sendable {

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    nonisolated static func live() -> ScribeDiagnosticsStore {
        ScribeDiagnosticsStore(directory: defaultDirectory())
    }

    /// Writes one payload and rotates. Returns the file written.
    @discardableResult
    func save(_ data: Data, kind: ScribeDiagnosticsKind, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let uniquifier = String(UUID().uuidString.prefix(8)).lowercased()
        let name = ScribeDiagnosticsRotation.fileName(kind: kind, date: date, uniquifier: uniquifier)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        rotate()
        return url
    }

    /// Stored payload files, newest first.
    func files() -> [ScribeDiagnosticsFile] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let files: [ScribeDiagnosticsFile] = urls.compactMap { url in
            let name = url.lastPathComponent
            guard let kind = ScribeDiagnosticsRotation.kind(ofFileName: name) else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return ScribeDiagnosticsFile(name: name, kind: kind, createdAt: date)
        }
        return files.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes files beyond `ScribeDiagnosticsRotation.maxFiles`.
    func rotate(limit: Int = ScribeDiagnosticsRotation.maxFiles) {
        for name in ScribeDiagnosticsRotation.filesToRemove(files(), limit: limit) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes every stored payload (Settings › About › Diagnostics).
    func removeAll() {
        for file in files() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.name))
        }
    }

    /// Copies every payload into a new `Scribe Diagnostics <date>` folder
    /// inside `parent`. Returns that folder.
    @discardableResult
    func export(into parent: URL, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fileManager = FileManager.default
        let baseName = "Scribe Diagnostics \(formatter.string(from: date))"
        var destination = parent.appendingPathComponent(baseName, isDirectory: true)
        // Two exports in the same second must not collide on copyItem.
        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(baseName) \(attempt)", isDirectory: true)
            attempt += 1
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files() {
            try fileManager.copyItem(
                at: directory.appendingPathComponent(file.name),
                to: destination.appendingPathComponent(file.name)
            )
        }
        return destination
    }
}
