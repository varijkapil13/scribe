// See AudioConversion: AVFAudio's converter-input block is `@Sendable`, but
// `AVAudioConverter.convert` runs it synchronously. `@preconcurrency` strips
// the imported Sendable annotations.
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

// MARK: - Overview
//
// System audio via Core Audio process taps (macOS 14.2+):
//
//   CATapDescription ──AudioHardwareCreateProcessTap──▶ tap
//   private aggregate device { taps: [tap] } ──IOProc──▶ realtime thread
//   realtime thread ──mixdown──▶ ProcessTapSampleRing (preallocated, lock-free)
//   work queue (40 ms timer) ──drain──▶ coalesce ──AVAudioConverter──▶ 16 kHz mono
//
// The IOProc runs on Core Audio's realtime thread, so it never allocates,
// locks or calls into Objective-C: it mixes the tap's channels to mono
// straight into a preallocated ring slot and publishes it with an atomic
// store. Everything else (conversion, delivery, setup, teardown, rebuilds
// after device changes) happens on one serial work queue.
//
// Every Core Audio call lives in a small throwing helper in
// `ProcessTapCoreAudio`, mapping OSStatus to `ProcessTapCaptureError`.

// MARK: - Errors

enum ProcessTapCaptureError: LocalizedError, Equatable {
    /// A Core Audio call failed.
    case coreAudio(operation: String, status: OSStatus)
    /// The tap delivers a sample format Scribe can't mix (not Float32 PCM).
    case unsupportedFormat
    /// The pipeline's output format couldn't be built.
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "System audio tap: \(operation) failed (\(ProcessTapCaptureError.describe(status)))."
        case .unsupportedFormat:
            return "System audio tap delivers an unsupported audio format."
        case .formatUnavailable:
            return "System audio tap couldn't set up its audio format."
        }
    }

    /// OSStatus as a four-character code when printable (`'nope'`), else
    /// the number.
    nonisolated static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(status)
    }

    /// Throws `.coreAudio` unless `status` is `noErr`.
    nonisolated static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ProcessTapCaptureError.coreAudio(operation: operation, status: status)
        }
    }
}

// MARK: - Format / timing / mixdown helpers (pure)

enum ProcessTapFormat {
    /// Whether the tap's stream is 32-bit float linear PCM — the only format
    /// the realtime mixdown handles. Interleaving and channel count are
    /// read per buffer, so any layout works.
    nonisolated static func isSupported(_ description: AudioStreamBasicDescription) -> Bool {
        description.mFormatID == kAudioFormatLinearPCM
            && (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && description.mBitsPerChannel == 32
            && description.mSampleRate > 0
    }
}

enum ProcessTapTiming {
    /// Host-clock ticks per audio frame.
    nonisolated static func ticksPerFrame(ticksPerSecond: Double, sampleRate: Double) -> Double {
        guard ticksPerSecond > 0, sampleRate > 0 else { return 0 }
        return ticksPerSecond / sampleRate
    }

    /// Host time of the frame `frameOffset` frames after `base`.
    /// Realtime-safe (pure arithmetic).
    nonisolated static func hostTime(base: UInt64, frameOffset: Int, ticksPerFrame: Double) -> UInt64 {
        guard frameOffset > 0, ticksPerFrame > 0 else { return base }
        return base &+ UInt64((Double(frameOffset) * ticksPerFrame).rounded())
    }

    /// Host time of the first of `frames` frames whose last one was captured
    /// just before `now` (used when Core Audio gives no host time).
    /// Realtime-safe; clamps at zero.
    nonisolated static func hostTime(endingAt now: UInt64, frames: Int, ticksPerFrame: Double) -> UInt64 {
        guard frames > 0, ticksPerFrame > 0 else { return now }
        let back = UInt64((Double(frames) * ticksPerFrame).rounded())
        return now > back ? now - back : 0
    }

    /// Whether audio starting at `actual` follows on from audio expected to
    /// continue at `expected`, within `toleranceTicks`.
    nonisolated static func isContiguous(expected: UInt64, actual: UInt64, toleranceTicks: Double) -> Bool {
        let difference = expected > actual ? expected - actual : actual - expected
        return Double(difference) <= max(0, toleranceTicks)
    }
}

enum ProcessTapMixdown {
    /// Frames in a Float32 buffer list: the shortest buffer, each holding
    /// `mNumberChannels` interleaved channels. 0 when nothing is readable.
    /// Realtime-safe.
    nonisolated static func frameCount(of list: UnsafeMutableAudioBufferListPointer) -> Int {
        var frames = Int.max
        var found = false
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, buffer.mData != nil else { continue }
            let count = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            frames = min(frames, count)
            found = true
        }
        return found ? frames : 0
    }

    /// Averages every channel of every buffer in `list` into `destination`
    /// for frames `frameOffset ..< frameOffset + frameCount`. Works for both
    /// interleaved (one buffer, N channels) and planar (N buffers, one
    /// channel) layouts. Frames a buffer doesn't have read as silence.
    /// Realtime-safe: no allocation, no locks.
    nonisolated static func mixToMono(
        _ list: UnsafeMutableAudioBufferListPointer,
        frameOffset: Int,
        frameCount: Int,
        into destination: UnsafeMutablePointer<Float>
    ) {
        guard frameCount > 0 else { return }
        destination.update(repeating: 0, count: frameCount)
        guard frameOffset >= 0 else { return }
        var totalChannels = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let raw = buffer.mData else { continue }
            totalChannels += channels
            let data = raw.assumingMemoryBound(to: Float.self)
            let available = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let end = min(frameOffset + frameCount, available)
            guard end > frameOffset else { continue }
            var frame = frameOffset
            while frame < end {
                let base = frame * channels
                var sum: Float = 0
                var channel = 0
                while channel < channels {
                    sum += data[base + channel]
                    channel += 1
                }
                destination[frame - frameOffset] += sum
                frame += 1
            }
        }
        guard totalChannels > 1 else { return }
        let scale = 1 / Float(totalChannels)
        var index = 0
        while index < frameCount {
            destination[index] *= scale
            index += 1
        }
    }

    /// Whether any sample is non-zero. A tap without System Audio Recording
    /// permission delivers exact digital silence.
    nonisolated static func containsSignal(_ samples: [Float]) -> Bool {
        samples.contains { $0 != 0 }
    }
}

// MARK: - ProcessTapSampleRing

/// Single-producer / single-consumer ring of fixed-size mono Float32 slots,
/// allocated once. The producer is the IOProc's realtime thread; the
/// consumer is the capture's work queue.
///
/// Each slot carries its frames and the host time of its first frame, so
/// timing survives overflow: when the consumer falls behind, whole callbacks
/// are dropped (counted in ``droppedSlots``) and the next slot still knows
/// exactly when it was captured.
///
/// `@unchecked Sendable`: slot memory is handed between the two threads by
/// the release store / acquire load of the indices — a slot is written only
/// while unpublished (`index >= readIndex + slotCount` is never written) and
/// read only once published.
final class ProcessTapSampleRing: @unchecked Sendable {

    let slotCount: Int
    let slotCapacity: Int
    /// Host-clock ticks per frame at the tap's sample rate.
    let ticksPerFrame: Double

    private let samples: UnsafeMutablePointer<Float>
    private let frameCounts: UnsafeMutablePointer<Int>
    private let hostTimes: UnsafeMutablePointer<UInt64>

    /// Slots published so far (written by the producer only).
    private let writeIndex = Atomic<Int>(0)
    /// Slots consumed so far (written by the consumer only).
    private let readIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(slotCount: Int, slotCapacity: Int, ticksPerFrame: Double) {
        self.slotCount = max(1, slotCount)
        self.slotCapacity = max(1, slotCapacity)
        self.ticksPerFrame = ticksPerFrame
        samples = UnsafeMutablePointer<Float>.allocate(capacity: self.slotCount * self.slotCapacity)
        samples.initialize(repeating: 0, count: self.slotCount * self.slotCapacity)
        frameCounts = UnsafeMutablePointer<Int>.allocate(capacity: self.slotCount)
        frameCounts.initialize(repeating: 0, count: self.slotCount)
        hostTimes = UnsafeMutablePointer<UInt64>.allocate(capacity: self.slotCount)
        hostTimes.initialize(repeating: 0, count: self.slotCount)
    }

    deinit {
        samples.deallocate()
        frameCounts.deallocate()
        hostTimes.deallocate()
    }

    /// Slots dropped because the consumer fell behind.
    var droppedSlots: Int { dropped.load(ordering: .relaxed) }

    /// Published slots not yet consumed.
    var pendingSlots: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    // MARK: Producer (realtime thread)

    /// Fills and publishes one slot. `fill` receives `frameCount` floats to
    /// write. Returns false (and counts a drop) when the ring is full or
    /// `frameCount` doesn't fit a slot. Realtime-safe.
    @discardableResult
    func write(frameCount: Int, hostTime: UInt64, _ fill: (UnsafeMutablePointer<Float>) -> Void) -> Bool {
        guard frameCount > 0, frameCount <= slotCapacity else { return false }
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard write - read < slotCount else {
            _ = dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        let slot = write % slotCount
        fill(samples + slot * slotCapacity)
        frameCounts[slot] = frameCount
        hostTimes[slot] = hostTime
        writeIndex.store(write + 1, ordering: .releasing)
        return true
    }

    /// The IOProc body: mixes the tap's input to mono into as many slots as
    /// the callback needs, stamping each with its capture host time.
    /// Realtime-safe: no allocation, no locks, no Objective-C.
    func ingest(inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let frames = ProcessTapMixdown.frameCount(of: list)
        guard frames > 0 else { return }
        let stamp = inputTime.pointee
        let base: UInt64
        if stamp.mFlags.contains(.hostTimeValid), stamp.mHostTime != 0 {
            base = stamp.mHostTime
        } else {
            base = ProcessTapTiming.hostTime(endingAt: mach_absolute_time(), frames: frames, ticksPerFrame: ticksPerFrame)
        }
        var offset = 0
        while offset < frames {
            let count = min(slotCapacity, frames - offset)
            let start = offset
            let host = ProcessTapTiming.hostTime(base: base, frameOffset: start, ticksPerFrame: ticksPerFrame)
            write(frameCount: count, hostTime: host) { destination in
                ProcessTapMixdown.mixToMono(list, frameOffset: start, frameCount: count, into: destination)
            }
            offset += count
        }
    }

    // MARK: Consumer (work queue)

    /// Hands every published slot to `body` in order (frames, first-frame
    /// host time), then frees it. The buffer is only valid inside `body`.
    /// Returns the number of slots read.
    @discardableResult
    func read(_ body: (UnsafeBufferPointer<Float>, UInt64) -> Void) -> Int {
        let start = readIndex.load(ordering: .relaxed)
        let end = writeIndex.load(ordering: .acquiring)
        var index = start
        while index < end {
            let slot = index % slotCount
            body(UnsafeBufferPointer(start: samples + slot * slotCapacity, count: frameCounts[slot]), hostTimes[slot])
            index += 1
            readIndex.store(index, ordering: .releasing)
        }
        return index - start
    }
}

// MARK: - ProcessTapCoalescer

/// A run of contiguous mono samples and the host time of its first one.
struct ProcessTapChunk: Equatable, Sendable {
    let samples: [Float]
    let startHostTime: UInt64
}

/// Joins consecutive ring slots into larger chunks (fewer, bigger buffers
/// for the converter and the main-actor hand-off), splitting wherever the
/// host times show a gap (dropped slots, a rebuilt tap) so every chunk's
/// start time stays exact. Pure; runs on the work queue.
struct ProcessTapCoalescer {
    let ticksPerFrame: Double
    let toleranceTicks: Double
    let maxFrames: Int

    private(set) var samples: [Float] = []
    private(set) var startHostTime: UInt64?

    init(ticksPerFrame: Double, toleranceTicks: Double, maxFrames: Int) {
        self.ticksPerFrame = ticksPerFrame
        self.toleranceTicks = toleranceTicks
        self.maxFrames = max(1, maxFrames)
        samples.reserveCapacity(self.maxFrames)
    }

    /// Adds one slot; returns the chunks completed by it (a gap before it,
    /// or reaching ``maxFrames``).
    mutating func append(_ slot: UnsafeBufferPointer<Float>, hostTime: UInt64) -> [ProcessTapChunk] {
        guard !slot.isEmpty else { return [] }
        var completed: [ProcessTapChunk] = []
        if let start = startHostTime, !samples.isEmpty {
            let expected = ProcessTapTiming.hostTime(base: start, frameOffset: samples.count, ticksPerFrame: ticksPerFrame)
            if !ProcessTapTiming.isContiguous(expected: expected, actual: hostTime, toleranceTicks: toleranceTicks),
               let chunk = flush() {
                completed.append(chunk)
            }
        }
        if samples.isEmpty { startHostTime = hostTime }
        samples.append(contentsOf: slot)
        if samples.count >= maxFrames, let chunk = flush() {
            completed.append(chunk)
        }
        return completed
    }

    /// Ends the current chunk, if any.
    mutating func flush() -> ProcessTapChunk? {
        guard let start = startHostTime, !samples.isEmpty else {
            startHostTime = nil
            return nil
        }
        let chunk = ProcessTapChunk(samples: samples, startHostTime: start)
        samples.removeAll(keepingCapacity: true)
        startHostTime = nil
        return chunk
    }
}

// MARK: - Core Audio helpers

/// Every Core Audio call the tap makes, each a small throwing (or
/// best-effort) function. Kept apart so an SDK signature change is a
/// one-line fix.
enum ProcessTapCoreAudio {

    nonisolated static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    nonisolated static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: Processes

    /// Core Audio's process object for `pid` (kAudioHardwarePropertyTranslatePIDToProcessObject),
    /// or `nil` when the process has none (it never touched Core Audio).
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject, &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &size, &object
        )
        try ProcessTapCaptureError.check(status, "translate process id")
        return object == AudioObjectID(kAudioObjectUnknown) ? nil : object
    }

    /// Every audio process object (kAudioHardwarePropertyProcessObjectList).
    static func processObjects() -> [AudioObjectID] {
        MicrophoneUsageMonitor.processObjectIDs()
    }

    static func bundleID(ofProcess object: AudioObjectID) -> String? {
        var address = globalAddress(kAudioProcessPropertyBundleID)
        // +1-retained CFStringRef, as in MicrophoneUsageMonitor.
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr,
              let value = ref?.takeRetainedValue() else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    static func pid(ofProcess object: AudioObjectID) -> pid_t? {
        var address = globalAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = globalAddress(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Process objects belonging to the meeting app `meetingBundleID`
    /// (excluding Scribe), sorted so sets compare stably.
    static func processObjects(forMeetingApp meetingBundleID: String) -> [AudioObjectID] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processObjects().filter { object in
            guard let bundle = bundleID(ofProcess: object), pid(ofProcess: object) != ownPID else { return false }
            return SystemAudioSourcePolicy.processBelongsToMeetingApp(
                processBundleID: bundle,
                meetingBundleID: meetingBundleID
            )
        }.sorted()
    }

    /// Whether any process other than Scribe is playing audio right now.
    static func isAnyOtherProcessRunningOutput() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processObjects().contains { object in
            isRunningOutput(object) && pid(ofProcess: object) != ownPID
        }
    }

    /// Whether any process the tap would hear is playing audio right now:
    /// the meeting app's processes when one is given, else any process
    /// other than Scribe.
    static func isTappedAudioPlaying(meetingBundleID: String?) -> Bool {
        guard let meetingBundleID else { return isAnyOtherProcessRunningOutput() }
        return processObjects(forMeetingApp: meetingBundleID).contains(where: isRunningOutput)
    }

    // MARK: Tap

    /// A stereo, private, unmuted tap description. `excluding` builds a
    /// global tap of everything but those processes; otherwise `including`
    /// taps just those.
    ///
    /// The `[AudioObjectID]` initializers are the Swift refinements of
    /// `initStereoGlobalTapButExcludeProcesses:` /
    /// `initStereoMixdownOfProcesses:` (NS_REFINED_FOR_SWIFT).
    static func makeTapDescription(
        excluding: [AudioObjectID]?,
        including: [AudioObjectID]
    ) -> CATapDescription {
        let description: CATapDescription
        if let excluding {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluding)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: including)
        }
        description.uuid = UUID()
        description.name = "Scribe system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    static func createProcessTap(_ description: CATapDescription) throws -> AudioObjectID {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try ProcessTapCaptureError.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
        guard tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw ProcessTapCaptureError.coreAudio(operation: "create process tap", status: kAudioHardwareUnspecifiedError)
        }
        return tapID
    }

    static func destroyProcessTap(_ tapID: AudioObjectID) {
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            Log.audio.error("Destroying the system audio tap failed (\(ProcessTapCaptureError.describe(status), privacy: .public)).")
        }
    }

    /// kAudioTapPropertyFormat: the format the tap's stream has in any
    /// aggregate device that contains it.
    static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = globalAddress(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try ProcessTapCaptureError.check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description),
            "read tap format"
        )
        return description
    }

    // MARK: Aggregate device

    /// A private aggregate device holding only the tap (no hardware
    /// sub-device, so a headset's mic can't leak into the remote track).
    /// Not auto-started by the tap: `AudioDeviceStart` would otherwise block
    /// until some app plays audio.
    static func createAggregateDevice(tapUUID: String) throws -> AudioObjectID {
        let tap: [String: Any] = [
            kAudioSubTapUIDKey: tapUUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let taps: [[String: Any]] = [tap]
        let subDevices: [[String: Any]] = []
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe System Audio",
            kAudioAggregateDeviceUIDKey: "com.varij.scribe.system-audio-tap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: taps,
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try ProcessTapCaptureError.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            "create aggregate device"
        )
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw ProcessTapCaptureError.coreAudio(operation: "create aggregate device", status: kAudioHardwareUnspecifiedError)
        }
        return deviceID
    }

    static func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        if status != noErr {
            Log.audio.error("Destroying the system audio aggregate device failed (\(ProcessTapCaptureError.describe(status), privacy: .public)).")
        }
    }

    // MARK: IOProc

    /// Installs the realtime IOProc. `ring` is passed unretained as client
    /// data: the caller must keep it alive until ``destroyIOProc(_:on:)``
    /// has returned. The callback captures nothing (a C function pointer).
    static func createIOProc(on deviceID: AudioObjectID, ring: ProcessTapSampleRing) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let context = Unmanaged.passUnretained(ring).toOpaque()
        let status = AudioDeviceCreateIOProcID(
            deviceID,
            { _, _, inputData, inputTime, _, _, clientData -> OSStatus in
                guard let clientData else { return noErr }
                Unmanaged<ProcessTapSampleRing>.fromOpaque(clientData)
                    .takeUnretainedValue()
                    .ingest(inputData: inputData, inputTime: inputTime)
                return noErr
            },
            context,
            &procID
        )
        try ProcessTapCaptureError.check(status, "create IOProc")
        guard let procID else {
            throw ProcessTapCaptureError.coreAudio(operation: "create IOProc", status: kAudioHardwareUnspecifiedError)
        }
        return procID
    }

    static func startDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID) throws {
        try ProcessTapCaptureError.check(AudioDeviceStart(deviceID, procID), "start aggregate device")
    }

    static func stopDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID) {
        let status = AudioDeviceStop(deviceID, procID)
        if status != noErr {
            Log.audio.error("Stopping the system audio aggregate device failed (\(ProcessTapCaptureError.describe(status), privacy: .public)).")
        }
    }

    static func destroyIOProc(_ procID: AudioDeviceIOProcID, on deviceID: AudioObjectID) {
        let status = AudioDeviceDestroyIOProcID(deviceID, procID)
        if status != noErr {
            Log.audio.error("Destroying the system audio IOProc failed (\(ProcessTapCaptureError.describe(status), privacy: .public)).")
        }
    }

    // MARK: Listeners

    static func addListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        var address = globalAddress(selector)
        try ProcessTapCaptureError.check(
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
            "add property listener"
        )
    }

    static func removeListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = globalAddress(selector)
        // The object may already be gone (a destroyed tap); failing is fine.
        _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

// MARK: - ProcessTapCapture

/// Captures other apps' audio through a Core Audio process tap and delivers
/// it like ``SystemAudioCapture``: 16 kHz (or the requested rate) mono
/// Float32 buffers, in order, on a private serial queue, stamped with their
/// host-clock start time.
///
/// By default the tap covers every process except Scribe. Given a meeting
/// app's bundle ID it taps only that app's processes (falling back to the
/// global tap when none are found). Tap, aggregate device and IOProc are
/// rebuilt when the default output device, the tap's format or (for a
/// per-app tap) the app's processes change.
///
/// There is no public preflight for the System Audio Recording permission:
/// the first start shows the system prompt, and a denied tap delivers
/// silence. ``hasObservedSignal`` lets ``SystemAudioRouter`` infer the grant.
///
/// `@unchecked Sendable`: callbacks and flags are lock-guarded; all Core
/// Audio objects and conversion state are touched only on `workQueue`.
final class ProcessTapCapture: SystemAudioSource, @unchecked Sendable {

    /// Process taps exist on every macOS Scribe supports (14.2+).
    nonisolated static let isSupported = true

    // MARK: Tuning

    /// Ring geometry: 512 slots × 1024 frames (2 MB) — over five seconds of
    /// headroom at 48 kHz with typical 512-frame IO cycles.
    private static let ringSlotCount = 512
    private static let ringSlotCapacity = 1024
    /// How often the work queue drains the ring, in milliseconds.
    private static let drainIntervalMilliseconds = 40
    /// Longest chunk handed to the converter at once.
    private static let maxChunkSeconds: Double = 0.2
    /// Host-time slack before consecutive slots count as a gap.
    private static let contiguityToleranceSeconds: Double = 0.005
    /// Debounce for device / process change notifications, in milliseconds.
    private static let rebuildDelayMilliseconds = 300

    // MARK: Lock-guarded state

    private let stateLock = NSLock()
    private var _isCapturing = false
    private var _hasObservedSignal = false
    private var _hasReceivedAudio = false
    private var _onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var _onStreamError: ((Error) -> Void)?
    private var _onCaptureWillRestart: (() -> Void)?

    var isCapturing: Bool { stateLock.withLock { _isCapturing } }

    /// Whether the current capture has delivered any non-zero sample.
    var hasObservedSignal: Bool { stateLock.withLock { _hasObservedSignal } }

    /// Whether the current capture has delivered any audio at all.
    var hasReceivedAudio: Bool { stateLock.withLock { _hasReceivedAudio } }

    var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { stateLock.withLock { _onAudioBuffer } }
        set { stateLock.withLock { _onAudioBuffer = newValue } }
    }

    /// Called when a rebuild after a device change fails and capture stops.
    var onStreamError: ((Error) -> Void)? {
        get { stateLock.withLock { _onStreamError } }
        set { stateLock.withLock { _onStreamError = newValue } }
    }

    /// Called (on the work queue) just before the tap is rebuilt after a
    /// device or process change, so the session can measure the gap.
    var onCaptureWillRestart: (() -> Void)? {
        get { stateLock.withLock { _onCaptureWillRestart } }
        set { stateLock.withLock { _onCaptureWillRestart = newValue } }
    }

    // MARK: Work-queue state

    private let workQueue = DispatchQueue(label: "com.varij.scribe.process-tap", qos: .userInitiated)

    /// One built tap + aggregate device + IOProc.
    private final class Run {
        let tapID: AudioObjectID
        let deviceID: AudioObjectID
        let procID: AudioDeviceIOProcID
        let ring: ProcessTapSampleRing
        /// Mono Float32 at the tap's sample rate.
        let tapFormat: AVAudioFormat
        /// Meeting-app processes a per-app tap covers (empty for global).
        let tappedProcesses: [AudioObjectID]

        init(tapID: AudioObjectID, deviceID: AudioObjectID, procID: AudioDeviceIOProcID,
             ring: ProcessTapSampleRing, tapFormat: AVAudioFormat, tappedProcesses: [AudioObjectID]) {
            self.tapID = tapID
            self.deviceID = deviceID
            self.procID = procID
            self.ring = ring
            self.tapFormat = tapFormat
            self.tappedProcesses = tappedProcesses
        }
    }

    private struct Request {
        let sampleRate: Double
        let meetingBundleID: String?
    }

    private struct Listener {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private var run: Run?
    private var request: Request?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var coalescer: ProcessTapCoalescer?
    private var drainTimer: DispatchSourceTimer?
    private var listeners: [Listener] = []
    private var rebuildToken = 0
    private var pendingRebuildNeedsFullRebuild = false
    private var lastDroppedSlots = 0

    init() {}

    // MARK: SystemAudioSource

    /// No public preflight exists; starting is the only way to find out.
    func checkPermission() async -> Bool { true }

    func startCapture(sampleRate: Double) async throws {
        try await startCapture(sampleRate: sampleRate, meetingBundleID: nil)
    }

    /// Starts capture. With `meetingBundleID`, taps only that app's audio
    /// processes when any exist (otherwise everything except Scribe).
    func startCapture(sampleRate: Double, meetingBundleID: String?) async throws {
        let request = Request(sampleRate: sampleRate, meetingBundleID: meetingBundleID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workQueue.async {
                do {
                    try self.start(request)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopCapture() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workQueue.async {
                self.stop()
                continuation.resume()
            }
        }
    }

    // MARK: Start / stop (work queue)

    private func start(_ request: Request) throws {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard run == nil else { return }
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: request.sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ProcessTapCaptureError.formatUnavailable }

        let newRun = try makeRun(for: request)
        self.request = request
        outputFormat = output
        install(newRun)
        stateLock.withLock {
            _isCapturing = true
            _hasObservedSignal = false
            _hasReceivedAudio = false
        }
        startDrainTimer()
        Log.audio.info("System audio tap started (\(newRun.tappedProcesses.isEmpty ? "all apps" : "meeting app only", privacy: .public), \(Int(newRun.tapFormat.sampleRate), privacy: .public) Hz).")
    }

    private func stop() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        rebuildToken += 1 // cancels a pending rebuild
        drainTimer?.cancel()
        drainTimer = nil
        if let run {
            teardown(run)
        }
        run = nil
        request = nil
        converter = nil
        outputFormat = nil
        stateLock.withLock { _isCapturing = false }
    }

    /// Makes `run` current: fresh coalescer and listeners.
    private func install(_ newRun: Run) {
        run = newRun
        lastDroppedSlots = 0
        let ticksPerFrame = newRun.ring.ticksPerFrame
        let ticksPerSecond = ticksPerFrame * newRun.tapFormat.sampleRate
        coalescer = ProcessTapCoalescer(
            ticksPerFrame: ticksPerFrame,
            toleranceTicks: Self.contiguityToleranceSeconds * ticksPerSecond,
            maxFrames: Int(Self.maxChunkSeconds * newRun.tapFormat.sampleRate)
        )
        installListeners(for: newRun)
    }

    // MARK: Building a run

    /// Builds tap → aggregate device → IOProc and starts the device,
    /// undoing whatever was built if a later step fails.
    private func makeRun(for request: Request) throws -> Run {
        let meetingProcesses = request.meetingBundleID.map(ProcessTapCoreAudio.processObjects(forMeetingApp:)) ?? []
        let scope = SystemAudioSourcePolicy.tapScope(
            meetingAppOnly: request.meetingBundleID != nil,
            meetingBundleID: request.meetingBundleID,
            matchingProcessCount: meetingProcesses.count
        )

        let description: CATapDescription
        let tapped: [AudioObjectID]
        switch scope {
        case .meetingApp:
            description = ProcessTapCoreAudio.makeTapDescription(excluding: nil, including: meetingProcesses)
            tapped = meetingProcesses
        case .global:
            description = ProcessTapCoreAudio.makeTapDescription(excluding: ownProcessObjects(), including: [])
            tapped = []
        }

        let tapID = try ProcessTapCoreAudio.createProcessTap(description)
        do {
            let streamFormat = try ProcessTapCoreAudio.tapFormat(tapID)
            guard ProcessTapFormat.isSupported(streamFormat) else {
                throw ProcessTapCaptureError.unsupportedFormat
            }
            guard let tapFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: streamFormat.mSampleRate,
                channels: 1,
                interleaved: false
            ) else { throw ProcessTapCaptureError.formatUnavailable }

            let deviceID = try ProcessTapCoreAudio.createAggregateDevice(tapUUID: description.uuid.uuidString)
            do {
                let ticksPerFrame = ProcessTapTiming.ticksPerFrame(
                    ticksPerSecond: Double(AVAudioTime.hostTime(forSeconds: 1)),
                    sampleRate: streamFormat.mSampleRate
                )
                let ring = ProcessTapSampleRing(
                    slotCount: Self.ringSlotCount,
                    slotCapacity: Self.ringSlotCapacity,
                    ticksPerFrame: ticksPerFrame
                )
                let procID = try ProcessTapCoreAudio.createIOProc(on: deviceID, ring: ring)
                do {
                    try ProcessTapCoreAudio.startDevice(deviceID, procID: procID)
                } catch {
                    ProcessTapCoreAudio.destroyIOProc(procID, on: deviceID)
                    throw error
                }
                return Run(tapID: tapID, deviceID: deviceID, procID: procID,
                           ring: ring, tapFormat: tapFormat, tappedProcesses: tapped)
            } catch {
                ProcessTapCoreAudio.destroyAggregateDevice(deviceID)
                throw error
            }
        } catch {
            ProcessTapCoreAudio.destroyProcessTap(tapID)
            throw error
        }
    }

    /// Scribe's own process object(s), excluded from the global tap so our
    /// own sounds (playback, the editor's web view) never reach the remote
    /// track. Empty when Scribe has none yet.
    private func ownProcessObjects() -> [AudioObjectID] {
        do {
            if let own = try ProcessTapCoreAudio.processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
                return [own]
            }
        } catch {
            Log.audio.error("Couldn't find Scribe's own audio process: \(error.localizedDescription, privacy: .public)")
        }
        return []
    }

    /// Stops the device, delivers what's left in the ring, then destroys
    /// IOProc → aggregate device → tap. The ring outlives the IOProc.
    private func teardown(_ old: Run) {
        removeListeners()
        ProcessTapCoreAudio.stopDevice(old.deviceID, procID: old.procID)
        drain(old)
        if let chunk = coalescer?.flush() {
            deliver(chunk, tapFormat: old.tapFormat)
        }
        coalescer = nil
        ProcessTapCoreAudio.destroyIOProc(old.procID, on: old.deviceID)
        ProcessTapCoreAudio.destroyAggregateDevice(old.deviceID)
        ProcessTapCoreAudio.destroyProcessTap(old.tapID)
    }

    // MARK: Device changes

    private func installListeners(for run: Run) {
        removeListeners()
        let system = ProcessTapCoreAudio.systemObject
        addListener(system, kAudioHardwarePropertyDefaultOutputDevice, processChangeOnly: false)
        addListener(run.tapID, kAudioTapPropertyFormat, processChangeOnly: false)
        // Whenever a meeting app was asked for — also while its processes are
        // missing and the global tap stands in — so the tap narrows to the
        // app as soon as it starts playing (or follows its new helpers).
        if request?.meetingBundleID != nil {
            addListener(system, kAudioHardwarePropertyProcessObjectList, processChangeOnly: true)
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, processChangeOnly: Bool) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild(processChangeOnly: processChangeOnly)
        }
        do {
            try ProcessTapCoreAudio.addListener(object, selector, queue: workQueue, block)
            listeners.append(Listener(object: object, selector: selector, block: block))
        } catch {
            Log.audio.error("System audio tap can't watch for device changes: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeListeners() {
        for listener in listeners {
            ProcessTapCoreAudio.removeListener(listener.object, listener.selector, queue: workQueue, listener.block)
        }
        listeners.removeAll()
    }

    /// Debounces change notifications (they arrive in bursts) into one
    /// rebuild. Runs on the work queue (the listeners' queue).
    private func scheduleRebuild(processChangeOnly: Bool) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard run != nil else { return }
        if !processChangeOnly { pendingRebuildNeedsFullRebuild = true }
        rebuildToken += 1
        let token = rebuildToken
        let delay = DispatchTimeInterval.milliseconds(Self.rebuildDelayMilliseconds)
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.rebuild(token: token)
        }
    }

    private func rebuild(token: Int) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard token == rebuildToken, let old = run, let request else { return }
        let full = pendingRebuildNeedsFullRebuild
        pendingRebuildNeedsFullRebuild = false
        if !full, let meeting = request.meetingBundleID,
           ProcessTapCoreAudio.processObjects(forMeetingApp: meeting) == old.tappedProcesses {
            return // the process list changed, but not the meeting app's part of it
        }

        Log.audio.info("Rebuilding the system audio tap after a device or process change.")
        teardown(old)
        run = nil
        converter = nil
        onCaptureWillRestart?()
        do {
            install(try makeRun(for: request))
        } catch {
            Log.audio.error("System audio tap couldn't restart: \(error.localizedDescription, privacy: .public)")
            drainTimer?.cancel()
            drainTimer = nil
            self.request = nil
            outputFormat = nil
            stateLock.withLock { _isCapturing = false }
            onStreamError?(error)
        }
    }

    // MARK: Draining (work queue)

    private func startDrainTimer() {
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        let interval = DispatchTimeInterval.milliseconds(Self.drainIntervalMilliseconds)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.drainTick()
        }
        drainTimer = timer
        timer.resume()
    }

    private func drainTick() {
        guard let run else { return }
        drain(run)
        if let chunk = coalescer?.flush() {
            deliver(chunk, tapFormat: run.tapFormat)
        }
        let dropped = run.ring.droppedSlots
        if dropped != lastDroppedSlots {
            Log.audio.error("System audio tap dropped \(dropped - self.lastDroppedSlots, privacy: .public) buffer(s): the work queue fell behind.")
            lastDroppedSlots = dropped
        }
    }

    /// Moves every published slot through the coalescer, delivering each
    /// completed chunk.
    private func drain(_ run: Run) {
        guard coalescer != nil else { return }
        var completed: [ProcessTapChunk] = []
        run.ring.read { slot, hostTime in
            if let chunks = coalescer?.append(slot, hostTime: hostTime) {
                completed.append(contentsOf: chunks)
            }
        }
        for chunk in completed {
            deliver(chunk, tapFormat: run.tapFormat)
        }
    }

    /// Converts one chunk to the output format and hands it on.
    private func deliver(_ chunk: ProcessTapChunk, tapFormat: AVAudioFormat) {
        guard !chunk.samples.isEmpty else { return }
        let sawSignal = ProcessTapMixdown.containsSignal(chunk.samples)
        stateLock.withLock {
            _hasReceivedAudio = true
            if sawSignal { _hasObservedSignal = true }
        }
        guard let callback = onAudioBuffer, let outputFormat else { return }
        guard let source = Self.makeBuffer(chunk.samples, format: tapFormat) else { return }

        let output: AVAudioPCMBuffer
        if source.format.isEqual(outputFormat) {
            output = source
        } else {
            // Long-lived so the resampler stays continuous across chunks;
            // replaced when a rebuild changed the tap's format.
            let reusable = converter.map {
                $0.inputFormat.isEqual(source.format) && $0.outputFormat.isEqual(outputFormat)
            } ?? false
            if !reusable {
                converter = AVAudioConverter(from: source.format, to: outputFormat)
            }
            guard let converter, let converted = AudioConversion.convert(source, using: converter) else { return }
            output = converted
        }
        callback(output, AVAudioTime(hostTime: chunk.startHostTime))
    }

    /// A mono Float32 buffer holding `samples`.
    static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress {
                channel[0].update(from: base, count: pointer.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
