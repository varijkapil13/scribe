// Scribe/Intelligence/Semantic/SemanticIndexScheduler.swift
import Combine
import Foundation

/// Keeps the semantic index up to date in the background while
/// "Semantic search (on-device)" is on.
///
/// A single background-priority loop runs small indexing passes (at most
/// ``batchSize`` model calls each) with a pause between batches, idles for
/// ``idleInterval`` once everything is indexed, and backs off while the Mac
/// is hot or in Low Power Mode (`HeavyWorkConditions`). ``kick()`` wakes it
/// early, e.g. after a recording was imported.
@MainActor
final class SemanticIndexScheduler {

    static let shared = SemanticIndexScheduler()

    /// Model calls per batch.
    nonisolated static let batchSize = 48
    /// Pause between batches while catching up.
    nonisolated static let batchPause: Duration = .seconds(2)
    /// Pause once the index is current.
    nonisolated static let idleInterval: Duration = .seconds(10 * 60)
    /// Pause while heavy work should be deferred.
    nonisolated static let deferInterval: Duration = .seconds(5 * 60)

    private var loop: Task<Void, Never>?
    private let wake = SemanticIndexWakeFlag()
    private var cancellables = Set<AnyCancellable>()
    private var isObserving = false

    private let indexer = SemanticIndexer(
        dbManager: .shared,
        store: SemanticEmbeddingStore(dbManager: .shared),
        embedder: NLSemanticEmbedder.shared
    )

    /// Starts following the setting (call once at launch).
    func start() {
        if !isObserving {
            isObserving = true
            let initial = SemanticSearchSettings.isEnabled()
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .map { _ in SemanticSearchSettings.isEnabled() }
                .changes(from: initial)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enabled in
                    self?.apply(enabled: enabled)
                }
                .store(in: &cancellables)
        }
        apply(enabled: SemanticSearchSettings.isEnabled())
    }

    /// Runs a pass soon (no-op while the feature is off).
    func kick() {
        guard loop != nil else { return }
        wake.set()
    }

    var isRunning: Bool { loop != nil }

    private func apply(enabled: Bool) {
        if enabled {
            guard loop == nil else { return }
            let indexer = self.indexer
            let wake = self.wake
            loop = Task.detached(priority: .background) {
                await Self.runLoop(indexer: indexer, wake: wake)
            }
            Log.intelligence.info("Semantic indexing started.")
        } else {
            loop?.cancel()
            loop = nil
            // Off the main thread: both wait on locks a running indexing
            // batch may hold (e.g. while the model loads).
            Task.detached(priority: .utility) {
                SemanticSearchService.shared.purgeCache()
                NLSemanticEmbedder.shared.unload()
            }
            Log.intelligence.info("Semantic indexing stopped.")
        }
    }

    /// The background loop. Runs off the main actor.
    nonisolated private static func runLoop(indexer: SemanticIndexer, wake: SemanticIndexWakeFlag) async {
        // Let launch settle first.
        try? await Task.sleep(for: .seconds(20))
        while !Task.isCancelled {
            if HeavyWorkConditions.shouldDeferNow() {
                await pause(deferInterval, orUntil: wake)
                continue
            }
            var complete = true
            do {
                let result = try indexer.runPass(maxEmbeddings: batchSize) { !Task.isCancelled }
                if result.changedIndex { SemanticSearchService.shared.invalidate() }
                complete = result.isComplete
                if result.embedded > 0 {
                    Log.intelligence.debug("Semantic index: embedded \(result.embedded) chunk(s), updated \(result.updatedSources) source(s).")
                }
            } catch {
                Log.intelligence.error("Semantic indexing pass failed: \(error.localizedDescription, privacy: .public)")
            }
            if complete {
                await pause(idleInterval, orUntil: wake)
            } else {
                try? await Task.sleep(for: batchPause)
            }
        }
    }

    /// Sleeps for `duration` (or until cancelled), returning early when
    /// ``kick()`` raised the wake flag. Polls the flag every couple of
    /// seconds, which is plenty for a background index.
    nonisolated private static func pause(_ duration: Duration, orUntil wake: SemanticIndexWakeFlag) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while !Task.isCancelled, clock.now < deadline {
            if wake.consume() { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// A lock-protected "run soon" flag shared with the background loop.
final class SemanticIndexWakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func set() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    /// Returns whether the flag was raised, lowering it.
    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = raised
        raised = false
        return value
    }
}
