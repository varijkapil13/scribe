import Foundation
#if os(macOS)
import Security
#endif

/// Whether this build can talk to CloudKit at all.
///
/// `CKContainer(identifier:)` raises an Objective-C exception (a crash, not a
/// thrown error) when the app isn't entitled for iCloud — which is the case
/// for the macOS app today (see Scribe.entitlements: the personal signing team
/// can't carry the iCloud capability). Callers check this BEFORE constructing
/// `CloudKitSyncService` / `TaskSyncCoordinator.live`, so the opt-in toggle can
/// be on while sync quietly stays a no-op until the container is provisioned.
enum CloudKitAvailability {

    static let iCloudServicesEntitlement = "com.apple.developer.icloud-services"

    /// True when the running binary carries the CloudKit iCloud service
    /// entitlement. Evaluated once per launch (entitlements can't change).
    static let isCloudKitEntitled: Bool = {
        #if os(macOS)
        return entitlementValueIncludesCloudKit(currentICloudServicesEntitlement())
        #else
        // iOS has no public API to read our own entitlements; the iOS target
        // ships Scribe-iOS.entitlements with CloudKit, so assume it's present
        // (unchanged behaviour for the existing iOS sync path).
        return true
        #endif
    }()

    /// Opt-in toggle on AND the binary can use CloudKit.
    static var canSyncTasks: Bool {
        CloudKitSyncService.isEnabled && isCloudKitEntitled
    }

    /// Interprets the value of `com.apple.developer.icloud-services`, which
    /// is normally an array of service names (["CloudKit", "CloudDocuments"])
    /// and may be the wildcard "*". Pure, so it's unit-tested.
    static func entitlementValueIncludesCloudKit(_ value: Any?) -> Bool {
        if let services = value as? [String] {
            return services.contains("CloudKit") || services.contains("*")
        }
        if let single = value as? String {
            return single == "CloudKit" || single == "*"
        }
        return false
    }

    #if os(macOS)
    /// Reads our own `com.apple.developer.icloud-services` entitlement via the
    /// Security framework's SecTask API (macOS only).
    private static func currentICloudServicesEntitlement() -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, iCloudServicesEntitlement as CFString, nil)
    }
    #endif
}
