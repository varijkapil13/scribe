// ScribeiOS/Notes/IOSLockedNoteSession.swift
//
// Locked notes on iPhone / iPad. Same envelope format as the Mac
// (`LockedNoteEnvelope`, AES-GCM); the keys come from iCloud Keychain
// (`LockedNoteSyncedKeyStore`) — the Mac publishes its key there, so a note
// locked on the Mac unlocks here after Face ID / Touch ID / the passcode.
// Keys stay in memory only while unlocked and are dropped when the app goes to
// the background or after a few idle minutes.

import CryptoKit
import Foundation
@preconcurrency import LocalAuthentication

extension Notification.Name {
    /// Posted on the main thread right before locked notes lock again on
    /// iOS. Open editors save (sealed) and drop their plaintext.
    static let scribeIOSLockedNotesWillLock = Notification.Name("scribe.ios.lockedNotesWillLock")
}

enum IOSLockedNoteError: Error, LocalizedError, Equatable {
    case authenticationUnavailable(String)
    case authenticationFailed(String)
    case cancelled
    /// No key on this device can open the envelope.
    case keyNotOnThisDevice

    var errorDescription: String? {
        switch self {
        case .authenticationUnavailable(let reason):
            return "This device can't confirm it's you: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .cancelled:
            return "Unlocking was cancelled."
        case .keyNotOnThisDevice:
            return "This note was locked on another device, and its key hasn't reached this one yet. Turn on iCloud Keychain on both devices, open Scribe on the Mac once, then try again."
        }
    }
}

@MainActor
@Observable
final class IOSLockedNoteSession {

    static let shared = IOSLockedNoteSession()

    /// Minutes without activity after which unlocked notes lock again.
    static let idleMinutes = 5

    private(set) var isUnlocked = false

    @ObservationIgnored private var keys: [SymmetricKey] = []
    @ObservationIgnored private var lastActivity = Date()

    private init() {}

    /// The in-memory keys while unlocked (counts as activity), or nil when
    /// locked / idle for too long.
    func currentKeys() -> [SymmetricKey]? {
        guard isUnlocked else { return nil }
        if Date().timeIntervalSince(lastActivity) >= TimeInterval(Self.idleMinutes * 60) {
            lock()
            return nil
        }
        lastActivity = Date()
        return keys
    }

    func noteActivity() {
        if isUnlocked { lastActivity = Date() }
    }

    /// Authenticates (when locked) and returns every locked-notes key this
    /// device knows.
    func unlock(reason: String) async throws -> [SymmetricKey] {
        if let keys = currentKeys() { return keys }
        try await Self.authenticate(reason: reason)
        let loaded = LockedNoteSyncedKeyStore.loadAll()
        keys = loaded
        lastActivity = Date()
        isUnlocked = true
        return loaded
    }

    /// The key a newly locked note is sealed with: the shared preferred key
    /// when one exists, else a new key published to iCloud Keychain (so the
    /// Mac and other devices can open it too).
    func sealingKey(reason: String) async throws -> SymmetricKey {
        let known = try await unlock(reason: reason)
        if let preferred = LockedNoteKeySelection.preferredSealingKey(known) { return preferred }
        let created = try LockedNoteSyncedKeyStore.createPublishedKey()
        keys = LockedNoteKeySelection.unique(keys + [created])
        return created
    }

    /// Locks every unlocked note now.
    func lock() {
        guard isUnlocked else { return }
        NotificationCenter.default.post(name: .scribeIOSLockedNotesWillLock, object: nil)
        keys = []
        isUnlocked = false
    }

    // MARK: - Authentication

    /// Face ID / Touch ID, falling back to the device passcode.
    nonisolated static func authenticate(reason: String) async throws {
        let context = LAContext()
        let result: Result<Void, IOSLockedNoteError> = await withCheckedContinuation { continuation in
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                continuation.resume(returning: .failure(.authenticationUnavailable(
                    error?.localizedDescription ?? "no passcode is set"
                )))
                return
            }
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evaluationError in
                if success {
                    continuation.resume(returning: .success(()))
                    return
                }
                let code = (evaluationError as NSError?)?.code ?? 0
                if code == LAError.userCancel.rawValue || code == LAError.appCancel.rawValue
                    || code == LAError.systemCancel.rawValue {
                    continuation.resume(returning: .failure(.cancelled))
                } else {
                    continuation.resume(returning: .failure(.authenticationFailed(
                        evaluationError?.localizedDescription ?? "unknown error"
                    )))
                }
            }
        }
        // The context must outlive the evaluation it runs.
        withExtendedLifetime(context) {}
        try result.get()
    }
}
