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

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
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
