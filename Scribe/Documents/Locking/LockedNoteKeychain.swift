// Scribe/Documents/Locking/LockedNoteKeychain.swift
//
// The locked-notes key: one random 256-bit AES key per Mac, kept in the
// login Keychain (service `com.varij.scribe.locked-notes`), plus a
// synchronizable copy in iCloud Keychain when available (see
// LockedNoteSyncedKeyStore) so the same notes unlock on iPhone / iPad.
// Reading it is gated by LocalAuthentication (`.deviceOwnerAuthentication`:
// Touch ID, Apple Watch or the Mac's login password) in `LockedNoteSession`.
//
// Why not a `.userPresence` access-control item: those live in the
// data-protection keychain, which needs a keychain-access-group entitlement
// the personal signing team can't provide; the generic-password item plus an
// explicit LocalAuthentication check works for every build.
//
// This file is the only place touching Security / LocalAuthentication.

import CryptoKit
import Foundation
@preconcurrency import LocalAuthentication
import Security

enum LockedNoteKeychainError: Error, LocalizedError {
    case keychain(OSStatus)
    case authenticationUnavailable(String)
    case authenticationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The Keychain couldn't provide the locked-notes key (error \(status))."
        case .authenticationUnavailable(let reason):
            return "This Mac can't confirm it's you: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .cancelled:
            return "Unlocking was cancelled."
        }
    }
}

enum LockedNoteKeychain {

    static let service = "com.varij.scribe.locked-notes"
    static let account = "master-key-v1"

    // MARK: - Authentication

    /// Asks for Touch ID / the login password. Throws `.cancelled` when the
    /// user dismissed the prompt.
    nonisolated static func authenticate(reason: String) async throws {
        let context = LAContext()
        let result: Result<Void, LockedNoteKeychainError> = await withCheckedContinuation { continuation in
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                continuation.resume(returning: .failure(.authenticationUnavailable(
                    error?.localizedDescription ?? "no passcode or biometrics are set up"
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

    // MARK: - Key storage

    private nonisolated static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored key, or nil when none was created yet.
    nonisolated static func loadKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw LockedNoteKeychainError.keychain(status)
        }
        return SymmetricKey(data: data)
    }

    /// Creates and stores a new random key. Only called when `loadKey()`
    /// found none — an existing key is never replaced (that would make every
    /// locked note unreadable).
    nonisolated static func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var add = baseQuery()
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrLabel as String] = "Scribe locked notes key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LockedNoteKeychainError.keychain(status) }
        return key
    }

    /// The stored key, creating one first when `create` is true.
    ///
    /// Cross-device: this Mac's key is also published to iCloud Keychain
    /// (`LockedNoteSyncedKeyStore`, best effort) so notes locked here open on
    /// iPhone / iPad; a Mac without its own key yet adopts one synced from
    /// another device. Both are no-ops when iCloud Keychain isn't available.
    nonisolated static func key(creatingIfNeeded create: Bool) throws -> SymmetricKey? {
        if let existing = try loadKey() {
            LockedNoteSyncedKeyStore.publish(existing)
            return existing
        }
        if let synced = LockedNoteKeySelection.preferredSealingKey(LockedNoteSyncedKeyStore.loadAll()) {
            return synced
        }
        guard create else { return nil }
        let key = try createKey()
        LockedNoteSyncedKeyStore.publish(key)
        return key
    }
}
