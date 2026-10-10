import CoreSpotlight
import Foundation
import GRDB
import UniformTypeIdentifiers

// MARK: - Identifiers

/// A Scribe item in the Spotlight index. The unique identifier is
/// `note:<id>` / `task:<id>`; continuing a Spotlight result parses it back.
enum SpotlightItemID: Hashable, Sendable {
    case note(String)
    case task(String)

    static let notePrefix = "note:"
    static let taskPrefix = "task:"

    static let noteDomain = "com.varij.scribe.notes"
    static let taskDomain = "com.varij.scribe.tasks"
    static let allDomains = [noteDomain, taskDomain]

    /// `note:<id>` / `task:<id>`.
    var uniqueIdentifier: String {
        switch self {
        case .note(let id): return Self.notePrefix + id
        case .task(let id): return Self.taskPrefix + id
        }
    }

    /// Parses `note:<id>` / `task:<id>`; nil for anything else (including an
    /// empty id).
    init?(uniqueIdentifier: String) {
        if uniqueIdentifier.hasPrefix(Self.notePrefix) {
            let id = String(uniqueIdentifier.dropFirst(Self.notePrefix.count))
            guard !id.isEmpty else { return nil }
            self = .note(id)
        } else if uniqueIdentifier.hasPrefix(Self.taskPrefix) {
            let id = String(uniqueIdentifier.dropFirst(Self.taskPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .task(id)
        } else {
            return nil
        }
    }

    var domainIdentifier: String {
        switch self {
        case .note: return Self.noteDomain
        case .task: return Self.taskDomain
        }
    }

    /// Where the main window goes when the result is opened.
    var selection: MainSelection {
        switch self {
        case .note(let id): return .note(id)
        case .task(let id): return .task(id)
        }
    }
}

// MARK: - Records + planning (pure)

/// What Spotlight shows for one item. Equality drives incremental updates:
/// an item is re-indexed only when its record changed.
struct SpotlightRecord: Equatable, Sendable {
    let itemID: SpotlightItemID
    let title: String
    let detail: String?
    let modifiedAt: Date
}

/// One indexing pass: optionally wipe Scribe's domains, then add/replace and
/// remove items.
struct SpotlightIndexPlan: Equatable, Sendable {
    var deleteAllFirst: Bool
    var upserts: [SpotlightRecord]
    var removals: [String]

    var isEmpty: Bool { !deleteAllFirst && upserts.isEmpty && removals.isEmpty }
}

enum SpotlightIndexPlanner {

    /// The Spotlight record for a note.
    nonisolated static func noteRecord(for note: Note) -> SpotlightRecord {
        SpotlightRecord(
            itemID: .note(note.id),
            title: ScribeIntentsText.displayTitle(note.title, fallback: "Untitled"),
            detail: note.bodyExcerpt,
            modifiedAt: note.updatedAt
        )
    }

    /// The Spotlight record for a task, or nil when it doesn't belong in the
    /// index (completed or cancelled tasks are left out).
    nonisolated static func taskRecord(for task: TodoTask) -> SpotlightRecord? {
        guard !task.isCompleted, !task.isCancelled else { return nil }
        var detailParts: [String] = []
        if let dueAt = task.dueAt {
            detailParts.append("Due " + dueAt.formatted(date: .abbreviated, time: .omitted))
        }
        let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { detailParts.append(notes) }
        return SpotlightRecord(
            itemID: .task(task.id),
            title: ScribeIntentsText.displayTitle(task.title, fallback: "Untitled task"),
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " — "),
            modifiedAt: task.updatedAt
        )
    }

    /// A full reindex is due when there never was one, or the last is older
    /// than `minimumInterval` (or in the future — clock change).
    nonisolated static func shouldFullReindex(lastFullReindex: Date?, now: Date, minimumInterval: TimeInterval) -> Bool {
        guard let lastFullReindex else { return true }
        let elapsed = now.timeIntervalSince(lastFullReindex)
        return elapsed < 0 || elapsed >= minimumInterval
    }

    /// Plans a pass from the current records.
    /// - `fullReindex`: wipe and index everything.
    /// - `previous == nil` (first pass since launch, not full): index what
    ///   changed since `lastPass` (everything when there was no pass yet);
    ///   removals wait for the next full reindex.
    /// - otherwise: index changed/new records and remove vanished ones.
    nonisolated static func plan(
        previous: [String: SpotlightRecord]?,
        current: [SpotlightRecord],
        fullReindex: Bool,
        lastPass: Date?
    ) -> SpotlightIndexPlan {
        if fullReindex {
            return SpotlightIndexPlan(deleteAllFirst: true, upserts: current, removals: [])
        }
        guard let previous else {
            let upserts = current.filter { record in
                guard let lastPass else { return true }
                return record.modifiedAt >= lastPass
            }
            return SpotlightIndexPlan(deleteAllFirst: false, upserts: upserts, removals: [])
        }
        let upserts = current.filter { previous[$0.itemID.uniqueIdentifier] != $0 }
        let currentIds = Set(current.map(\.itemID.uniqueIdentifier))
        let removals = previous.keys.filter { !currentIds.contains($0) }.sorted()
        return SpotlightIndexPlan(deleteAllFirst: false, upserts: upserts, removals: removals)
    }

    /// Records keyed by unique identifier (first wins on a duplicate).
    nonisolated static func snapshot(of records: [SpotlightRecord]) -> [String: SpotlightRecord] {
        var result: [String: SpotlightRecord] = [:]
        for record in records where result[record.itemID.uniqueIdentifier] == nil {
            result[record.itemID.uniqueIdentifier] = record
        }
        return result
    }
}

// MARK: - Indexer

/// Keeps Spotlight in step with notes and tasks.
///
/// - Launch: one pass in the background — a full reindex at most once a day
///   (throttled), otherwise just what changed since the last pass.
/// - Saves / deletes: a GRDB region observation on `notes` + `tasks` pings
///   the indexer; passes are debounced and never overlap, and each one diffs
///   against the previous pass so only changed items are re-indexed and
///   deleted ones are removed.
/// - Opening a result: `SpotlightIndexer.handle(_:)` routes it to the note /
///   task in the main window.
///
/// Users can turn indexing off (Settings → Shortcuts), which removes Scribe's
/// items from Spotlight.
@MainActor
final class SpotlightIndexer {

    static let shared = SpotlightIndexer(dbManager: DatabaseManager.shared, defaults: UserDefaults.standard)

    /// `NSUserActivity` type Spotlight uses when a result is opened.
    nonisolated static let activityType = CSSearchableItemActionType

    nonisolated static let enabledKey = "spotlight.indexingEnabled"
    nonisolated static let lastFullReindexKey = "spotlight.lastFullReindexAt"
    nonisolated static let lastPassKey = "spotlight.lastPassAt"

    /// Full reindex at most this often (on launch / when re-enabled).
    static let fullReindexInterval: TimeInterval = 24 * 60 * 60
    /// Coalesces bursts of saves (the editor autosaves while typing).
    static let changeDebounce: Duration = .seconds(3)

    private let dbManager: DatabaseManager
    private let defaults: UserDefaults

    private var started = false
    private var observation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?
    private var passInFlight = false
    private var pendingPass = false
    private var forceFullReindex = false
    /// Records as of the last pass; nil until the first pass this launch.
    private var snapshot: [String: SpotlightRecord]?

    init(dbManager: DatabaseManager, defaults: UserDefaults) {
        self.dbManager = dbManager
        self.defaults = defaults
    }

    /// Whether the user allows Scribe items in Spotlight (default on).
    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Starts observing and runs the launch pass. Idempotent; no-op when the
    /// user turned indexing off or Spotlight isn't available.
    func start() {
        guard !started, isEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        started = true
        observation = Self.observeChanges(in: dbManager.database) { [weak self] in
            // Re-capture weakly by value: a nested Sendable closure may not
            // capture the outer closure's `weak var self` by reference.
            Task { @MainActor [weak self] in self?.storeDidChange() }
        }
        runPass()
    }

    /// Turns indexing on (full reindex) or off (removes Scribe's items).
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            defaults.removeObject(forKey: Self.lastFullReindexKey)
            if started {
                forceFullReindex = true
                runPass()
            } else {
                start()
            }
        } else {
            stop()
            Self.removeAllItems()
            defaults.removeObject(forKey: Self.lastFullReindexKey)
            defaults.removeObject(forKey: Self.lastPassKey)
        }
    }

    private func stop() {
        observation?.cancel()
        observation = nil
        debounceTask?.cancel()
        debounceTask = nil
        started = false
        pendingPass = false
        snapshot = nil
    }

    // MARK: - Passes

    private func storeDidChange() {
        guard started else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled, let self else { return }
            self.runPass()
        }
    }

    private func runPass() {
        guard started else { return }
        guard !passInFlight else {
            pendingPass = true
            return
        }
        passInFlight = true

        let now = Date()
        let lastFull = defaults.object(forKey: Self.lastFullReindexKey) as? Date
        let full = forceFullReindex || SpotlightIndexPlanner.shouldFullReindex(
            lastFullReindex: lastFull, now: now, minimumInterval: Self.fullReindexInterval
        )
        forceFullReindex = false
        let previous = snapshot
        let lastPass = defaults.object(forKey: Self.lastPassKey) as? Date
        let manager = dbManager

        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                SpotlightIndexer.performPass(manager: manager, previous: previous, fullReindex: full, lastPass: lastPass)
            }.value
            self?.finishPass(records: outcome, startedAt: now, wasFull: full)
        }
    }

    private func finishPass(records: [SpotlightRecord]?, startedAt: Date, wasFull: Bool) {
        passInFlight = false
        guard started else {
            // Turned off while this pass was indexing: its items may have
            // landed after the removal, so remove them again.
            if !isEnabled { Self.removeAllItems() }
            return
        }
        if let records {
            snapshot = SpotlightIndexPlanner.snapshot(of: records)
            defaults.set(startedAt, forKey: Self.lastPassKey)
            if wasFull { defaults.set(startedAt, forKey: Self.lastFullReindexKey) }
        } else if wasFull {
            // Failed full pass: try again next time.
            forceFullReindex = true
        }
        if pendingPass {
            pendingPass = false
            runPass()
        }
    }

    /// Reads the records, plans and submits the pass. Runs off the main
    /// actor. Returns the records indexed, or nil when reading failed.
    nonisolated private static func performPass(
        manager: DatabaseManager,
        previous: [String: SpotlightRecord]?,
        fullReindex: Bool,
        lastPass: Date?
    ) -> [SpotlightRecord]? {
        let records: [SpotlightRecord]
        do {
            records = try fetchRecords(manager: manager)
        } catch {
            Log.storage.error("Spotlight: reading notes/tasks failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let plan = SpotlightIndexPlanner.plan(
            previous: previous, current: records, fullReindex: fullReindex, lastPass: lastPass
        )
        submit(plan)
        return records
    }

    nonisolated private static func fetchRecords(manager: DatabaseManager) throws -> [SpotlightRecord] {
        let rows = try manager.database.read { database -> ([Note], [TodoTask]) in
            let notes = try Note.fetchAll(database)
            let tasks = try TodoTask.fetchAll(database)
            return (notes, tasks)
        }
        let noteRecords = rows.0.map { SpotlightIndexPlanner.noteRecord(for: $0) }
        let taskRecords = rows.1.compactMap { SpotlightIndexPlanner.taskRecord(for: $0) }
        return noteRecords + taskRecords
    }

    /// Removes every Scribe item from Spotlight.
    nonisolated private static func removeAllItems() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: SpotlightItemID.allDomains) { error in
            if let error {
                Log.storage.error("Spotlight: removing items failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sends a plan to Spotlight. CoreSpotlight serves one client's requests
    /// in order, so the wipe of a full reindex lands before the re-add.
    nonisolated private static func submit(_ plan: SpotlightIndexPlan) {
        guard !plan.isEmpty else { return }
        let index = CSSearchableIndex.default()
        if plan.deleteAllFirst {
            index.deleteSearchableItems(withDomainIdentifiers: SpotlightItemID.allDomains) { error in
                if let error {
                    Log.storage.error("Spotlight: clearing items failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if !plan.removals.isEmpty {
            index.deleteSearchableItems(withIdentifiers: plan.removals) { error in
                if let error {
                    Log.storage.error("Spotlight: removing items failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if !plan.upserts.isEmpty {
            let items = plan.upserts.map(makeItem(for:))
            index.indexSearchableItems(items) { error in
                if let error {
                    Log.storage.error("Spotlight: indexing failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    nonisolated private static func makeItem(for record: SpotlightRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = record.title
        attributes.contentDescription = record.detail
        attributes.contentModificationDate = record.modifiedAt
        let item = CSSearchableItem(
            uniqueIdentifier: record.itemID.uniqueIdentifier,
            domainIdentifier: record.itemID.domainIdentifier,
            attributeSet: attributes
        )
        // Items otherwise expire after a default period even when unchanged.
        item.expirationDate = Date.distantFuture
        return item
    }

    /// Pings `onChange` after every committed write to `notes` or `tasks`.
    /// `nonisolated` so GRDB's change callback isn't a main-actor closure.
    nonisolated private static func observeChanges(
        in database: DatabaseQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: Note.all(), TodoTask.all())
        return observation.start(
            in: database,
            onError: { error in
                Log.storage.error("Spotlight change observation failed: \(error.localizedDescription, privacy: .private)")
            },
            onChange: { _ in onChange() }
        )
    }

    // MARK: - Continuing a Spotlight result

    /// Opens the note / task behind a Spotlight result in the main window.
    /// Returns false when `activity` isn't a Scribe Spotlight result.
    @discardableResult
    static func handle(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == activityType,
              let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let item = SpotlightItemID(uniqueIdentifier: raw)
        else { return false }
        let data = ScribeIntentsData.live
        let exists: Bool
        switch item {
        case .note(let id): exists = !((try? data.notes(ids: [id])) ?? []).isEmpty
        case .task(let id): exists = !((try? data.tasks(ids: [id])) ?? []).isEmpty
        }
        guard exists else {
            // Stale result (deleted since the last pass): drop it and land on
            // the list it came from instead of a dead page.
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [raw]) { _ in }
            switch item {
            case .note: ScribeMainWindowNavigator.show(.notes(.all))
            case .task: ScribeMainWindowNavigator.show(.tasks(.inbox))
            }
            return true
        }
        ScribeMainWindowNavigator.show(item.selection)
        return true
    }
}
