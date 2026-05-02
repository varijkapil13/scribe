import XCTest
@testable import Scribe

/// Realistic tests for ``AudioBufferManager`` exercising chunk timing, overlap
/// retention, dual-stream interleaving, and concurrent producers — the
/// conditions the live audio pipeline runs into during an actual recording.
final class AudioBufferIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    /// Default 16 kHz / 5 s chunk / 1 s overlap matches the production config
    /// in `AudioBufferManager.init` defaults.
    private func makeManager(
        sampleRate: Int = 16_000,
        chunkSeconds: Double = 5.0,
        overlapSeconds: Double = 1.0
    ) -> AudioBufferManager {
        AudioBufferManager(
            sampleRate: sampleRate,
            chunkDurationSeconds: chunkSeconds,
            overlapDurationSeconds: overlapSeconds
        )
    }

    // MARK: - Chunk emission

    func testNoChunkEmittedBelowThreshold() {
        let manager = makeManager()
        var emitted = 0
        manager.onChunkReady = { _, _ in emitted += 1 }

        // 4.99 s of audio — short of the 5 s chunk.
        manager.appendMicSamples([Float](repeating: 0.1, count: 79_840))
        XCTAssertEqual(emitted, 0)
    }

    func testExactlyOneChunkEmitsExactSampleCount() {
        let manager = makeManager()
        var captured: [(samples: [Float], speaker: String)] = []
        manager.onChunkReady = { samples, speaker in
            captured.append((samples, speaker))
        }

        manager.appendMicSamples([Float](repeating: 0.5, count: 80_000))
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].samples.count, 80_000)
        XCTAssertEqual(captured[0].speaker, "you")
        XCTAssertEqual(captured[0].samples.first, 0.5)
    }

    func testTwoChunksFromTenSecondsRetainsOverlap() {
        let manager = makeManager()
        var emittedSampleCounts: [Int] = []
        manager.onChunkReady = { samples, _ in emittedSampleCounts.append(samples.count) }

        // Feed 10 s in one append.
        manager.appendMicSamples([Float](repeating: 0.2, count: 160_000))

        // Two full chunks of 80 000 samples each.
        XCTAssertEqual(emittedSampleCounts, [80_000, 80_000])
    }

    func testOverlapPreservesContextSamples() {
        // Use unique sample values so we can prove the overlap is retained.
        let manager = makeManager()
        var captured: [[Float]] = []
        manager.onChunkReady = { samples, _ in captured.append(samples) }

        // First chunk: ramp from 0...79999.
        let first = (0..<80_000).map { Float($0) }
        manager.appendMicSamples(first)
        XCTAssertEqual(captured.count, 1)

        // Now feed enough additional samples to trigger a second chunk. The
        // overlap is 16 000 samples (1 s @ 16 kHz), so we only need
        // 80 000 - 16 000 = 64 000 more samples.
        let second = (0..<64_000).map { Float($0 + 1_000_000) }
        manager.appendMicSamples(second)

        XCTAssertEqual(captured.count, 2)

        // Last 16 000 samples of the first chunk should reappear at the head
        // of the second chunk.
        let overlapHead = Array(captured[1].prefix(16_000))
        let overlapExpected = Array(first.suffix(16_000))
        XCTAssertEqual(overlapHead, overlapExpected)
    }

    func testMicAndSystemBuffersRouteToCorrectSpeakerLabel() {
        let manager = makeManager()
        var labels: [String] = []
        manager.onChunkReady = { _, speaker in labels.append(speaker) }

        manager.appendMicSamples([Float](repeating: 0, count: 80_000))
        manager.appendSystemSamples([Float](repeating: 0, count: 80_000))

        XCTAssertEqual(labels, ["you", "remote"])
    }

    func testInterleavedMicAndSystemEmissionsDoNotMix() {
        let manager = makeManager()
        var events: [(speaker: String, firstSample: Float)] = []
        manager.onChunkReady = { samples, speaker in
            events.append((speaker, samples.first ?? .nan))
        }

        // Feed just under threshold on each stream.
        manager.appendMicSamples([Float](repeating: 1.0, count: 60_000))
        manager.appendSystemSamples([Float](repeating: 2.0, count: 60_000))
        // Each below threshold individually — no chunks yet.
        XCTAssertEqual(events.count, 0)

        // Now top each one up across the threshold.
        manager.appendMicSamples([Float](repeating: 1.0, count: 20_000))
        manager.appendSystemSamples([Float](repeating: 2.0, count: 20_000))

        XCTAssertEqual(events.count, 2)
        let micEvents = events.filter { $0.speaker == "you" }
        let remoteEvents = events.filter { $0.speaker == "remote" }
        XCTAssertEqual(micEvents.count, 1)
        XCTAssertEqual(remoteEvents.count, 1)
        XCTAssertEqual(micEvents.first?.firstSample, 1.0)
        XCTAssertEqual(remoteEvents.first?.firstSample, 2.0)
    }

    // MARK: - Reset

    func testResetClearsBothBuffers() {
        let manager = makeManager()
        var emitted = 0
        manager.onChunkReady = { _, _ in emitted += 1 }

        manager.appendMicSamples([Float](repeating: 0.1, count: 70_000))
        manager.appendSystemSamples([Float](repeating: 0.1, count: 70_000))
        manager.reset()

        // After reset, partial buffers are gone — must feed a full chunk to emit.
        manager.appendMicSamples([Float](repeating: 0.5, count: 70_000))
        XCTAssertEqual(emitted, 0)

        manager.appendMicSamples([Float](repeating: 0.5, count: 10_000))
        XCTAssertEqual(emitted, 1)
    }

    // MARK: - Edge cases

    func testEmptyAppendDoesNothing() {
        let manager = makeManager()
        var emitted = 0
        manager.onChunkReady = { _, _ in emitted += 1 }

        manager.appendMicSamples([])
        manager.appendSystemSamples([])
        XCTAssertEqual(emitted, 0)
    }

    func testCustomConfigurationDeterminesChunkSize() {
        // 8 kHz, 2 s chunk, 0.5 s overlap → 16 000 sample chunks.
        let manager = makeManager(sampleRate: 8_000, chunkSeconds: 2.0, overlapSeconds: 0.5)
        var captured: [Int] = []
        manager.onChunkReady = { samples, _ in captured.append(samples.count) }

        manager.appendMicSamples([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(captured, [16_000])
    }

    func testHugeAppendEmitsManyChunks() {
        let manager = makeManager()
        var count = 0
        manager.onChunkReady = { _, _ in count += 1 }

        // 60 s of mic audio at 16 kHz = 960 000 samples. The buffer emits a
        // 80 000-sample chunk and retains 16 000 (the overlap), so each
        // emission shrinks the buffer by 64 000 samples. Emissions continue
        // while buffer ≥ 80 000:
        //   ceil((960_000 - 80_000) / 64_000) + 1 = 14 chunks.
        manager.appendMicSamples([Float](repeating: 0, count: 16_000 * 60))
        XCTAssertEqual(count, 14)
    }

    // MARK: - Concurrency

    func testConcurrentAppendsFromMultipleThreadsDoNotCrash() {
        let manager = makeManager()
        let count = NSCountedSet()
        let lock = NSLock()
        manager.onChunkReady = { _, speaker in
            lock.lock()
            count.add(speaker)
            lock.unlock()
        }

        let queue = DispatchQueue(label: "test.audio.producer", attributes: .concurrent)
        let group = DispatchGroup()

        // 8 producers each feeding 80 000 samples. AudioBufferManager uses an
        // NSLock internally so this should be safe.
        for i in 0..<8 {
            group.enter()
            queue.async {
                let samples = [Float](repeating: Float(i), count: 80_000)
                if i.isMultiple(of: 2) {
                    manager.appendMicSamples(samples)
                } else {
                    manager.appendSystemSamples(samples)
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)

        // Each producer fed exactly one chunk's worth of samples; we expect
        // ≥ 4 chunks per stream (could be more due to overlap retention
        // accumulating across appends, but never fewer).
        XCTAssertGreaterThanOrEqual(count.count(for: "you"), 4)
        XCTAssertGreaterThanOrEqual(count.count(for: "remote"), 4)
    }
}
