import CoreAudio
import Foundation

/// Reports which *processes* are currently capturing audio input, via the
/// CoreAudio process-object API (macOS 14.2+).
///
/// This answers "who is using the mic" — the same signal that drives the
/// orange menu-bar dot — which is what meeting detection needs. It differs
/// from `MicrophoneCapture.runningInputDeviceIDs()`, which answers "which
/// *device* is in use" for picking the mic to record from.
///
/// Scribe's own process is always excluded, so our own recording never looks
/// like a meeting.
enum MicrophoneUsageMonitor {

    struct InputProcess: Equatable, Sendable {
        let pid: pid_t
        let bundleID: String
    }

    /// Every process (other than Scribe) whose audio input is running now.
    static func activeInputProcesses() -> [InputProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processObjectIDs().compactMap { object in
            guard isRunningInput(object), let pid = pid(of: object), pid != ownPID else { return nil }
            return InputProcess(pid: pid, bundleID: bundleID(of: object) ?? "")
        }
    }

    // MARK: - CoreAudio

    /// System-object property listing every audio process object.
    static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Per-process property: is this process's audio input running.
    static let isRunningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func processObjectIDs() -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = isRunningInputAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // +1-retained CFStringRef — same pattern as the device-name read in
        // MicrophoneCapture.availableInputDevices().
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr,
              let value = ref?.takeRetainedValue() else { return nil }
        return value as String
    }
}

// MARK: - Change notifications

/// Notifies when any process starts or stops capturing audio input, via
/// CoreAudio property listeners: the system object's process list (processes
/// appearing / disappearing) and each process object's "is running input"
/// flag. Lets meeting detection react to the mic being taken instead of
/// polling for it.
///
/// Same threading model as `MicrophoneCapture`'s device listeners: blocks run
/// on the main queue; `onChange` is called there. Declared
/// `@unchecked Sendable` so the CoreAudio blocks can capture it weakly.
final class MicrophoneUsageObserver: @unchecked Sendable {

    /// Called on the main queue after any relevant change.
    var onChange: (() -> Void)?

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    /// True while the process-list listener is installed.
    var isObserving: Bool { processListListener != nil }

    /// Installs the listeners. Returns false when CoreAudio refused the
    /// process-list listener (callers should poll instead). Idempotent.
    @discardableResult
    func start() -> Bool {
        guard processListListener == nil else { return true }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // New processes need their own listener; gone ones are dropped.
            self.syncProcessListeners()
            self.onChange?()
        }
        var address = MicrophoneUsageMonitor.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            Log.audio.error("Failed to observe audio process list (status \(status)).")
            return false
        }
        processListListener = block
        syncProcessListeners()
        return true
    }

    /// Removes every listener. Idempotent.
    func stop() {
        if let block = processListListener {
            var address = MicrophoneUsageMonitor.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
            processListListener = nil
        }
        var address = MicrophoneUsageMonitor.isRunningInputAddress
        for (object, block) in processListeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        processListeners.removeAll()
    }

    deinit {
        stop()
    }

    /// Adds an "is running input" listener to each process object that
    /// doesn't have one, and forgets objects that no longer exist.
    private func syncProcessListeners() {
        let current = Set(MicrophoneUsageMonitor.processObjectIDs())
        var address = MicrophoneUsageMonitor.isRunningInputAddress

        let gone = processListeners.filter { !current.contains($0.key) }
        for (object, block) in gone {
            // The object is usually already destroyed; removal failing is fine.
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
            processListeners[object] = nil
        }

        for object in current where processListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onChange?()
            }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
            if status == noErr {
                processListeners[object] = block
            }
        }
    }
}
