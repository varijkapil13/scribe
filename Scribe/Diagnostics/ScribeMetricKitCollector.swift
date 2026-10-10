import Foundation
import MetricKit

/// Subscribes to MetricKit and keeps the payloads it delivers — crash, hang
/// and CPU-exception diagnostics plus the daily metric summary — as JSON in
/// `~/Library/Application Support/Scribe/Diagnostics` (rotating, at most
/// `ScribeDiagnosticsRotation.maxFiles` files).
///
/// Nothing is sent anywhere: the files only leave the Mac if the user exports
/// them from Settings › About › Diagnostics and shares them by hand.
///
/// MetricKit calls the subscriber on a background queue, so this class is
/// deliberately not main-actor isolated; its only state is the immutable store.
final class ScribeMetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = ScribeMetricKitCollector(store: ScribeDiagnosticsStore.live())

    private let store: ScribeDiagnosticsStore
    private let lock = NSLock()
    private var started = false

    init(store: ScribeDiagnosticsStore) {
        self.store = store
        super.init()
    }

    /// Registers with MetricKit. Idempotent. Called once at launch.
    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persist(payload.jsonRepresentation(), kind: .metric)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persist(payload.jsonRepresentation(), kind: .diagnostic)
        }
    }

    private func persist(_ data: Data, kind: ScribeDiagnosticsKind) {
        do {
            try store.save(data, kind: kind, date: Date())
        } catch {
            Log.app.error("Saving a \(kind.rawValue, privacy: .public) payload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
