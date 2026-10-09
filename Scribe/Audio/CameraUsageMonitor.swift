import CoreMediaIO
import Foundation

/// Reports whether any camera is in use by any process, via CoreMediaIO's
/// per-device "is running somewhere" flag — the same signal behind the green
/// camera light. Reading it needs no camera permission and never opens the
/// camera.
///
/// CoreMediaIO can't say *which* process holds the camera, so meeting
/// detection only uses this as a booster alongside the per-process mic signal
/// from `MicrophoneUsageMonitor` (see `MeetingSignals`).
enum CameraUsageMonitor {

    /// True when at least one video device is running in some process.
    static func isAnyCameraInUse() -> Bool {
        deviceIDs().contains(where: isRunningSomewhere)
    }

    // MARK: - CoreMediaIO

    private static func propertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            // kCMIOObjectPropertyElementMain (== 0, formerly ...ElementMaster);
            // spelled numerically so the code doesn't depend on which name
            // the SDK exports.
            mElement: CMIOObjectPropertyElement(0)
        )
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var address = propertyAddress(Int(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        // Same pattern as MicrophoneUsageMonitor: note CoreMediaIO takes the
        // buffer size by value and reports bytes written via `used`.
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = propertyAddress(Int(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value)
        return status == noErr && value != 0
    }
}
