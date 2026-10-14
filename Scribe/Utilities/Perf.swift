import Foundation
import os

/// Signposts and main-thread stall detection. Intervals show up in Instruments
/// under "Points of Interest" (subsystem = bundle id, category `perf`); stalls
/// are logged to the `perf` category, e.g.
/// `log stream --predicate 'subsystem == "com.varij.scribe" AND category == "perf"'`.
enum Perf {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.varij.scribe"

    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    static let log = Logger(subsystem: subsystem, category: "perf")

    static let slowThreshold: Duration = .milliseconds(16)

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let clock = ContinuousClock()
        let start = clock.now
        defer {
            signposter.endInterval(name, state)
            let elapsed = clock.now - start
            if elapsed > slowThreshold {
                log.warning("slow \(name, privacy: .public): \(elapsed.inMilliseconds, privacy: .public) ms")
            }
        }
        return try body()
    }

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let clock = ContinuousClock()
        let start = clock.now
        defer {
            signposter.endInterval(name, state)
            let elapsed = clock.now - start
            if elapsed > slowThreshold {
                log.warning("slow \(name, privacy: .public): \(elapsed.inMilliseconds, privacy: .public) ms")
            }
        }
        return try await body()
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

/// Pings the main queue from a background timer and logs any stall longer than
/// `threshold`, so hitches are visible in Console without attaching Instruments.
final class MainThreadStallMonitor: @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    private let queue = DispatchQueue(label: "com.varij.scribe.stall-monitor", qos: .utility)
    private let threshold: Duration = .milliseconds(100)
    private let interval: DispatchTimeInterval = .milliseconds(250)
    private var timer: DispatchSourceTimer?
    private var awaitingPing = false

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.ping() }
            timer.resume()
            self.timer = timer
        }
    }

    private func ping() {
        guard !awaitingPing else { return }
        awaitingPing = true
        let clock = ContinuousClock()
        let sent = clock.now
        DispatchQueue.main.async { [self] in
            let stall = clock.now - sent
            queue.async { [self] in
                awaitingPing = false
                if stall > threshold {
                    Perf.signposter.emitEvent("main-thread stall")
                    Perf.log.warning("main thread stalled \(stall.inMilliseconds, privacy: .public) ms")
                }
            }
        }
    }
}

extension Duration {
    var inMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
