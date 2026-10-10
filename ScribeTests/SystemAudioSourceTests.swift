// ScribeTests/SystemAudioSourceTests.swift
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import Scribe

// MARK: - Source selection policy

final class SystemAudioSourcePolicyTests: XCTestCase {

    private let tap = SystemAudioBackendKind.processTap
    private let sck = SystemAudioBackendKind.screenCaptureKit

    private func plan(
        _ preference: SystemAudioSourcePreference,
        _ permission: ProcessTapPermissionState,
        tapSupported: Bool = true,
        screen: Bool
    ) -> [SystemAudioBackendKind] {
        SystemAudioSourcePolicy.plan(
            preference: preference,
            tapPermission: permission,
            tapSupported: tapSupported,
            screenCapturePermitted: screen
        )
    }

    func testAutomaticPrefersTapWithScreenCaptureKitFallback() {
        let automatic = SystemAudioSourcePreference.automatic
        XCTAssertEqual(plan(automatic, ProcessTapPermissionState.unknown, screen: true), [tap, sck])
        XCTAssertEqual(plan(automatic, ProcessTapPermissionState.granted, screen: true), [tap, sck])
        XCTAssertEqual(plan(automatic, ProcessTapPermissionState.unknown, screen: false), [tap])
        XCTAssertEqual(plan(automatic, ProcessTapPermissionState.granted, screen: false), [tap])
    }

    func testAutomaticWithSuspectedDenialPrefersScreenCaptureKit() {
        let automatic = SystemAudioSourcePreference.automatic
        let denied = ProcessTapPermissionState.suspectedDenied
        XCTAssertEqual(plan(automatic, denied, screen: true), [sck, tap])
        // Without Screen Recording the tap is still worth a try.
        XCTAssertEqual(plan(automatic, denied, screen: false), [tap])
    }

    func testAutomaticWithoutTapSupportUsesScreenCaptureKitOnly() {
        let automatic = SystemAudioSourcePreference.automatic
        XCTAssertEqual(plan(automatic, ProcessTapPermissionState.unknown, tapSupported: false, screen: true), [sck])
        XCTAssertEqual(plan(automatic, ProcessTapPermissionState.granted, tapSupported: false, screen: false), [])
    }

    func testExplicitScreenCaptureKitNeverUsesTheTap() {
        let explicit = SystemAudioSourcePreference.screenCaptureKit
        for permission in ProcessTapPermissionState.allCases {
            XCTAssertEqual(plan(explicit, permission, screen: true), [sck])
            XCTAssertEqual(plan(explicit, permission, screen: false), [])
        }
    }

    func testRequiresScreenRecordingOnlyWhenNothingElseWorks() {
        XCTAssertFalse(SystemAudioSourcePolicy.requiresScreenRecording(
            preference: SystemAudioSourcePreference.automatic,
            tapPermission: ProcessTapPermissionState.unknown,
            tapSupported: true
        ))
        XCTAssertFalse(SystemAudioSourcePolicy.requiresScreenRecording(
            preference: SystemAudioSourcePreference.automatic,
            tapPermission: ProcessTapPermissionState.suspectedDenied,
            tapSupported: true
        ))
        XCTAssertTrue(SystemAudioSourcePolicy.requiresScreenRecording(
            preference: SystemAudioSourcePreference.automatic,
            tapPermission: ProcessTapPermissionState.unknown,
            tapSupported: false
        ))
        XCTAssertTrue(SystemAudioSourcePolicy.requiresScreenRecording(
            preference: SystemAudioSourcePreference.screenCaptureKit,
            tapPermission: ProcessTapPermissionState.granted,
            tapSupported: true
        ))
    }

    func testFallbackIsTheNextBackendInThePlan() {
        XCTAssertEqual(SystemAudioSourcePolicy.fallback(after: tap, in: [tap, sck]), sck)
        XCTAssertNil(SystemAudioSourcePolicy.fallback(after: sck, in: [tap, sck]))
        XCTAssertEqual(SystemAudioSourcePolicy.fallback(after: sck, in: [sck, tap]), tap)
        XCTAssertNil(SystemAudioSourcePolicy.fallback(after: tap, in: [tap]))
        XCTAssertNil(SystemAudioSourcePolicy.fallback(after: tap, in: [sck]))
        XCTAssertNil(SystemAudioSourcePolicy.fallback(after: tap, in: []))
    }

    func testTapScopeIsPerAppOnlyWhenAskedAndProcessesExist() {
        let global = SystemAudioSourcePolicy.TapScope.global
        let perApp = SystemAudioSourcePolicy.TapScope.meetingApp
        XCTAssertEqual(SystemAudioSourcePolicy.tapScope(meetingAppOnly: true, meetingBundleID: "us.zoom.xos", matchingProcessCount: 2), perApp)
        XCTAssertEqual(SystemAudioSourcePolicy.tapScope(meetingAppOnly: false, meetingBundleID: "us.zoom.xos", matchingProcessCount: 2), global)
        XCTAssertEqual(SystemAudioSourcePolicy.tapScope(meetingAppOnly: true, meetingBundleID: "us.zoom.xos", matchingProcessCount: 0), global)
        XCTAssertEqual(SystemAudioSourcePolicy.tapScope(meetingAppOnly: true, meetingBundleID: nil, matchingProcessCount: 3), global)
        XCTAssertEqual(SystemAudioSourcePolicy.tapScope(meetingAppOnly: true, meetingBundleID: "", matchingProcessCount: 3), global)
    }

    func testProcessMatchingCoversHelpersAndCatalogAliases() {
        func belongs(_ process: String, _ meeting: String) -> Bool {
            SystemAudioSourcePolicy.processBelongsToMeetingApp(processBundleID: process, meetingBundleID: meeting)
        }
        XCTAssertTrue(belongs("us.zoom.xos", "us.zoom.xos"))
        XCTAssertTrue(belongs("com.google.Chrome.helper", "com.google.Chrome"))
        XCTAssertTrue(belongs("com.microsoft.teams2.helper", "com.microsoft.teams2"))
        // Safari plays through the shared WebKit GPU process.
        XCTAssertTrue(belongs("com.apple.WebKit.GPU", "com.apple.Safari"))
        XCTAssertFalse(belongs("com.apple.Music", "us.zoom.xos"))
        XCTAssertFalse(belongs("us.zoom.xosx", "us.zoom.xos"))
        XCTAssertFalse(belongs("com.tinyspeck.slackmacgap", "us.zoom.xos"))
        XCTAssertFalse(belongs("", "us.zoom.xos"))
        XCTAssertFalse(belongs("us.zoom.xos", ""))
    }
}

// MARK: - Stored settings

final class SystemAudioSourceSettingsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults?

    override func setUp() {
        super.setUp()
        suiteName = "SystemAudioSourceSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPreferenceDefaultsToAutomatic() throws {
        let defaults = try XCTUnwrap(defaults)
        XCTAssertEqual(SystemAudioSourcePreference.current(in: defaults), SystemAudioSourcePreference.automatic)
        defaults.set("bogus", forKey: SystemAudioSourcePreference.defaultsKey)
        XCTAssertEqual(SystemAudioSourcePreference.current(in: defaults), SystemAudioSourcePreference.automatic)
        defaults.set("screenCaptureKit", forKey: SystemAudioSourcePreference.defaultsKey)
        XCTAssertEqual(SystemAudioSourcePreference.current(in: defaults), SystemAudioSourcePreference.screenCaptureKit)
    }

    func testPermissionStateRoundTrips() throws {
        let defaults = try XCTUnwrap(defaults)
        XCTAssertEqual(ProcessTapPermissionState.load(from: defaults), ProcessTapPermissionState.unknown)
        ProcessTapPermissionState.suspectedDenied.store(in: defaults)
        XCTAssertEqual(ProcessTapPermissionState.load(from: defaults), ProcessTapPermissionState.suspectedDenied)
        ProcessTapPermissionState.granted.store(in: defaults)
        XCTAssertEqual(ProcessTapPermissionState.load(from: defaults), ProcessTapPermissionState.granted)
    }

    func testPreferenceTitlesNameBothSources() {
        XCTAssertEqual(SystemAudioSourcePreference.automatic.title, "Automatic (Core Audio tap)")
        XCTAssertEqual(SystemAudioSourcePreference.screenCaptureKit.title, "ScreenCaptureKit")
    }
}

// MARK: - Permission probe

final class ProcessTapPermissionProbeTests: XCTestCase {

    func testSignalProvesTheGrant() {
        var probe = ProcessTapPermissionProbe(suspicionThresholdSeconds: 4, maxProbeSeconds: 10)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: true), ProcessTapPermissionProbe.Verdict.undecided)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: true, othersPlaying: true), ProcessTapPermissionProbe.Verdict.granted)
    }

    func testLongSilenceWhileOthersPlayLooksDenied() {
        var probe = ProcessTapPermissionProbe(suspicionThresholdSeconds: 4, maxProbeSeconds: 10)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: true), ProcessTapPermissionProbe.Verdict.undecided)
        // Quiet stretches don't count towards suspicion.
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: false), ProcessTapPermissionProbe.Verdict.undecided)
        XCTAssertEqual(probe.suspiciousSeconds, 2)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: true), ProcessTapPermissionProbe.Verdict.suspectedDenied)
    }

    func testGivesUpWhenNothingIsPlaying() {
        var probe = ProcessTapPermissionProbe(suspicionThresholdSeconds: 4, maxProbeSeconds: 6)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: false), ProcessTapPermissionProbe.Verdict.undecided)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: false), ProcessTapPermissionProbe.Verdict.undecided)
        XCTAssertEqual(probe.observe(intervalSeconds: 2, sawSignal: false, othersPlaying: false), ProcessTapPermissionProbe.Verdict.inconclusive)
    }

    func testNegativeIntervalsAreIgnored() {
        var probe = ProcessTapPermissionProbe(suspicionThresholdSeconds: 4, maxProbeSeconds: 6)
        XCTAssertEqual(probe.observe(intervalSeconds: -100, sawSignal: false, othersPlaying: true), ProcessTapPermissionProbe.Verdict.undecided)
        XCTAssertEqual(probe.elapsedSeconds, 0)
        XCTAssertEqual(probe.suspiciousSeconds, 0)
    }

    func testDefaultThresholdsAreGenerous() {
        let probe = ProcessTapPermissionProbe()
        XCTAssertGreaterThanOrEqual(probe.suspicionThresholdSeconds, 10)
        XCTAssertGreaterThan(probe.maxProbeSeconds, probe.suspicionThresholdSeconds)
    }
}

// MARK: - Process tap helpers

final class ProcessTapHelperTests: XCTestCase {

    // MARK: Errors

    func testOSStatusDescribesFourCharCodes() {
        // 'nope'
        let nope = OSStatus(0x6E6F_7065)
        XCTAssertEqual(ProcessTapCaptureError.describe(nope), "'nope'")
        XCTAssertEqual(ProcessTapCaptureError.describe(-50), "-50")
    }

    func testCheckThrowsOnlyOnFailure() {
        XCTAssertNoThrow(try ProcessTapCaptureError.check(noErr, "start"))
        XCTAssertThrowsError(try ProcessTapCaptureError.check(-50, "start")) { error in
            XCTAssertEqual(error as? ProcessTapCaptureError, ProcessTapCaptureError.coreAudio(operation: "start", status: -50))
        }
    }

    // MARK: Format

    private func streamDescription(flags: AudioFormatFlags, bits: UInt32, rate: Double = 48_000) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bits / 8 * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: bits / 8 * 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: bits,
            mReserved: 0
        )
    }

    func testOnlyFloat32PCMIsSupported() {
        XCTAssertTrue(ProcessTapFormat.isSupported(streamDescription(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, bits: 32)))
        XCTAssertTrue(ProcessTapFormat.isSupported(streamDescription(
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, bits: 32)))
        XCTAssertFalse(ProcessTapFormat.isSupported(streamDescription(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, bits: 16)))
        XCTAssertFalse(ProcessTapFormat.isSupported(streamDescription(flags: kAudioFormatFlagIsFloat, bits: 64)))
        XCTAssertFalse(ProcessTapFormat.isSupported(streamDescription(flags: kAudioFormatFlagIsFloat, bits: 32, rate: 0)))
    }

    // MARK: Timing

    func testTicksPerFrame() {
        XCTAssertEqual(ProcessTapTiming.ticksPerFrame(ticksPerSecond: 48_000_000, sampleRate: 48_000), 1_000)
        XCTAssertEqual(ProcessTapTiming.ticksPerFrame(ticksPerSecond: 48_000_000, sampleRate: 0), 0)
        XCTAssertEqual(ProcessTapTiming.ticksPerFrame(ticksPerSecond: 0, sampleRate: 48_000), 0)
    }

    func testHostTimeOffsets() {
        XCTAssertEqual(ProcessTapTiming.hostTime(base: 1_000, frameOffset: 3, ticksPerFrame: 10), 1_030)
        XCTAssertEqual(ProcessTapTiming.hostTime(base: 1_000, frameOffset: 0, ticksPerFrame: 10), 1_000)
        XCTAssertEqual(ProcessTapTiming.hostTime(base: 1_000, frameOffset: -5, ticksPerFrame: 10), 1_000)
        XCTAssertEqual(ProcessTapTiming.hostTime(base: 1_000, frameOffset: 3, ticksPerFrame: 2.5), 1_008)
    }

    func testHostTimeEndingNowClampsAtZero() {
        XCTAssertEqual(ProcessTapTiming.hostTime(endingAt: 1_000, frames: 50, ticksPerFrame: 10), 500)
        XCTAssertEqual(ProcessTapTiming.hostTime(endingAt: 1_000, frames: 500, ticksPerFrame: 10), 0)
        XCTAssertEqual(ProcessTapTiming.hostTime(endingAt: 1_000, frames: 0, ticksPerFrame: 10), 1_000)
    }

    func testContiguityTolerance() {
        XCTAssertTrue(ProcessTapTiming.isContiguous(expected: 1_000, actual: 1_004, toleranceTicks: 5))
        XCTAssertTrue(ProcessTapTiming.isContiguous(expected: 1_004, actual: 1_000, toleranceTicks: 5))
        XCTAssertFalse(ProcessTapTiming.isContiguous(expected: 1_000, actual: 1_006, toleranceTicks: 5))
        XCTAssertTrue(ProcessTapTiming.isContiguous(expected: 1_000, actual: 1_000, toleranceTicks: -1))
    }

    // MARK: Mixdown

    /// Runs `body` with a buffer list holding `buffers` (each: channel count
    /// and interleaved samples).
    private func withBufferList(
        _ buffers: [(channels: UInt32, samples: [Float])],
        _ body: (UnsafeMutableAudioBufferListPointer) -> Void
    ) {
        var list = AudioBufferList.allocate(maximumBuffers: max(1, buffers.count))
        defer { free(list.unsafeMutablePointer) }
        list.count = buffers.count
        var storage: [UnsafeMutablePointer<Float>] = []
        defer { storage.forEach { $0.deallocate() } }
        for (index, buffer) in buffers.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, buffer.samples.count))
            pointer.initialize(from: buffer.samples, count: buffer.samples.count)
            storage.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
        body(list)
    }

    private func mix(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 99, count: count)
        out.withUnsafeMutableBufferPointer { pointer in
            if let base = pointer.baseAddress {
                ProcessTapMixdown.mixToMono(list, frameOffset: offset, frameCount: count, into: base)
            }
        }
        return out
    }

    func testInterleavedStereoAveragesChannels() {
        withBufferList([(channels: 2, samples: [1, 3, 2, 4, -1, 1])]) { list in
            XCTAssertEqual(ProcessTapMixdown.frameCount(of: list), 3)
            XCTAssertEqual(mix(list, offset: 0, count: 3), [2, 3, 0])
            XCTAssertEqual(mix(list, offset: 1, count: 2), [3, 0])
            // Past the end reads as silence.
            XCTAssertEqual(mix(list, offset: 2, count: 2), [0, 0])
        }
    }

    func testPlanarBuffersAverageAcrossBuffers() {
        withBufferList([(channels: 1, samples: [1, 2, 3]), (channels: 1, samples: [3, 4, 5])]) { list in
            XCTAssertEqual(ProcessTapMixdown.frameCount(of: list), 3)
            XCTAssertEqual(mix(list, offset: 0, count: 3), [2, 3, 4])
        }
    }

    func testMonoPassesThrough() {
        withBufferList([(channels: 1, samples: [0.5, -0.25])]) { list in
            XCTAssertEqual(mix(list, offset: 0, count: 2), [0.5, -0.25])
        }
    }

    func testFrameCountUsesTheShortestBuffer() {
        withBufferList([(channels: 1, samples: [1, 2, 3, 4]), (channels: 1, samples: [1, 2])]) { list in
            XCTAssertEqual(ProcessTapMixdown.frameCount(of: list), 2)
        }
        withBufferList([]) { list in
            XCTAssertEqual(ProcessTapMixdown.frameCount(of: list), 0)
        }
    }

    func testSignalDetection() {
        XCTAssertFalse(ProcessTapMixdown.containsSignal([0, 0, 0]))
        XCTAssertFalse(ProcessTapMixdown.containsSignal([]))
        XCTAssertTrue(ProcessTapMixdown.containsSignal([0, 0.0001, 0]))
    }

    // MARK: Ring

    private func readAll(_ ring: ProcessTapSampleRing) -> [(samples: [Float], hostTime: UInt64)] {
        var slots: [(samples: [Float], hostTime: UInt64)] = []
        ring.read { slot, hostTime in slots.append((Array(slot), hostTime)) }
        return slots
    }

    /// A ring `fill` closure writing `values`.
    private func filler(_ values: [Float]) -> (UnsafeMutablePointer<Float>) -> Void {
        { pointer in
            for (index, value) in values.enumerated() { pointer[index] = value }
        }
    }

    func testRingDeliversSlotsInOrderAndDropsWhenFull() {
        let ring = ProcessTapSampleRing(slotCount: 2, slotCapacity: 4, ticksPerFrame: 1)
        XCTAssertTrue(ring.write(frameCount: 2, hostTime: 10, filler([1, 2])))
        XCTAssertTrue(ring.write(frameCount: 1, hostTime: 20, filler([3])))
        XCTAssertFalse(ring.write(frameCount: 1, hostTime: 30, filler([4])))
        XCTAssertEqual(ring.droppedSlots, 1)
        XCTAssertEqual(ring.pendingSlots, 2)

        let slots = readAll(ring)
        XCTAssertEqual(slots.map { $0.samples }, [[1, 2], [3]])
        XCTAssertEqual(slots.map { $0.hostTime }, [10, 20])
        XCTAssertEqual(ring.pendingSlots, 0)

        // Freed slots are reused.
        XCTAssertTrue(ring.write(frameCount: 1, hostTime: 40, filler([5])))
        XCTAssertEqual(readAll(ring).map { $0.samples }, [[5]])
    }

    func testRingRejectsOversizedAndEmptyWrites() {
        let ring = ProcessTapSampleRing(slotCount: 2, slotCapacity: 2, ticksPerFrame: 1)
        XCTAssertFalse(ring.write(frameCount: 3, hostTime: 0, filler([1, 2, 3])))
        XCTAssertFalse(ring.write(frameCount: 0, hostTime: 0, filler([])))
        XCTAssertEqual(ring.pendingSlots, 0)
    }

    func testIngestSplitsLongCallbacksAndStampsEachSlot() {
        let ring = ProcessTapSampleRing(slotCount: 8, slotCapacity: 2, ticksPerFrame: 10)
        withBufferList([(channels: 2, samples: [1, 1, 2, 2, 3, 3])]) { list in
            var stamp = AudioTimeStamp()
            stamp.mHostTime = 1_000
            stamp.mFlags = .hostTimeValid
            withUnsafePointer(to: stamp) { time in
                ring.ingest(inputData: list.unsafePointer, inputTime: time)
            }
        }
        let slots = readAll(ring)
        XCTAssertEqual(slots.map { $0.samples }, [[1, 2], [3]])
        XCTAssertEqual(slots.map { $0.hostTime }, [1_000, 1_020])
    }

    // MARK: Coalescer

    private func append(_ coalescer: inout ProcessTapCoalescer, _ samples: [Float], at hostTime: UInt64) -> [ProcessTapChunk] {
        samples.withUnsafeBufferPointer { coalescer.append($0, hostTime: hostTime) }
    }

    func testCoalescerJoinsContiguousSlots() {
        var coalescer = ProcessTapCoalescer(ticksPerFrame: 10, toleranceTicks: 5, maxFrames: 100)
        XCTAssertEqual(append(&coalescer, [1, 2], at: 0), [])
        XCTAssertEqual(append(&coalescer, [3], at: 22), []) // within tolerance of 20
        XCTAssertEqual(coalescer.flush(), ProcessTapChunk(samples: [1, 2, 3], startHostTime: 0))
        XCTAssertNil(coalescer.flush())
    }

    func testCoalescerSplitsAtGaps() {
        var coalescer = ProcessTapCoalescer(ticksPerFrame: 10, toleranceTicks: 5, maxFrames: 100)
        XCTAssertEqual(append(&coalescer, [1, 2], at: 0), [])
        XCTAssertEqual(append(&coalescer, [3], at: 500), [ProcessTapChunk(samples: [1, 2], startHostTime: 0)])
        XCTAssertEqual(coalescer.flush(), ProcessTapChunk(samples: [3], startHostTime: 500))
    }

    func testCoalescerFlushesAtMaxFrames() {
        var coalescer = ProcessTapCoalescer(ticksPerFrame: 10, toleranceTicks: 5, maxFrames: 3)
        XCTAssertEqual(append(&coalescer, [1, 2], at: 0), [])
        XCTAssertEqual(append(&coalescer, [3, 4], at: 20), [ProcessTapChunk(samples: [1, 2, 3, 4], startHostTime: 0)])
        XCTAssertEqual(append(&coalescer, [5], at: 40), [])
        XCTAssertEqual(coalescer.flush(), ProcessTapChunk(samples: [5], startHostTime: 40))
    }

    func testCoalescerIgnoresEmptySlots() {
        var coalescer = ProcessTapCoalescer(ticksPerFrame: 10, toleranceTicks: 5, maxFrames: 3)
        XCTAssertEqual(append(&coalescer, [], at: 0), [])
        XCTAssertNil(coalescer.flush())
    }

    // MARK: Buffers

    func testMakeBufferCopiesSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(ProcessTapCapture.makeBuffer([0.25, -0.5, 1], format: format))
        XCTAssertEqual(buffer.frameLength, 3)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel[0], count: 3)), [0.25, -0.5, 1])
        XCTAssertNil(ProcessTapCapture.makeBuffer([], format: format))
    }
}
