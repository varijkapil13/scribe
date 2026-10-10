// Scribe/Sync/LockedNoteSyncedKeyStore.swift
//
// Locked notes across devices. A locked note's file holds a
// `LockedNoteEnvelope` (AES-GCM) whose `Key:` header names the key it was
// sealed with. The Mac keeps its key as a per-Mac login-Keychain item
// (`LockedNoteKeychain`, service `com.varij.scribe.locked-notes`, account
// `master-key-v1`, ThisDeviceOnly — it never leaves that Mac).
//
// To open on iPhone / iPad a note locked on the Mac, every key is ALSO
// published as an iCloud Keychain (synchronizable, data-protection keychain)
// item under the same service and the account `synced-key-<keyId>`. One item
// per key id, so keys created on different devices before they first synced
// coexist instead of colliding; the reader picks the key whose id matches the
// envelope header (`LockedNoteKeySelection`).
//
// Without iCloud Keychain (or without the keychain entitlement, as on the
// personal signing team) the synced calls fail softly and every device keeps
// working with its local key alone.
//
// Portable Security/CryptoKit; compiled into the macOS app and the iOS target.

import CryptoKit
import Foundation
import Security

/// Pure key choice for locked notes (unit-tested, no Keychain).
enum LockedNoteKeySelection {

    /// The key in `candidates` that sealed `armored` (matched by the
    /// envelope's `Key:` header), or nil when none did / it isn't an envelope.
    nonisolated static func key(for armored: String, among candidates: [SymmetricKey]) -> SymmetricKey? {
        guard let parsed = try? LockedNoteEnvelope.parse(armored) else { return nil }
        return candidates.first { LockedNoteEnvelope.keyIdentifier(for: $0) == parsed.keyId }
    }

    /// The key new envelopes are sealed with when several are known: the one
    /// with the smallest identifier, so every device picks the same key from
    /// the same synced set. nil when there are none.
    nonisolated static func preferredSealingKey(_ candidates: [SymmetricKey]) -> SymmetricKey? {
        candidates.min { LockedNoteEnvelope.keyIdentifier(for: $0) < LockedNoteEnvelope.keyIdentifier(for: $1) }
    }

    /// Keychain account of the synced item for `key`.
    nonisolated static func syncedAccount(for key: SymmetricKey) -> String {
        LockedNoteSyncedKeyStore.syncedAccountPrefix + LockedNoteEnvelope.keyIdentifier(for: key)
    }

    /// Drops duplicate keys (same identifier), keeping the first of each.
    nonisolated static func unique(_ keys: [SymmetricKey]) -> [SymmetricKey] {
        var seen = Set<String>()
        return keys.filter { seen.insert(LockedNoteEnvelope.keyIdentifier(for: $0)).inserted }
    }
}

/// The iCloud Keychain copies of the locked-notes keys.
enum LockedNoteSyncedKeyStore {

    /// Same service as the Mac's `LockedNoteKeychain.service`.
    static let service = "com.varij.scribe.locked-notes"
    static let syncedAccountPrefix = "synced-key-"

    private nonisolated static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: true,
            // macOS: the iCloud-syncable data-protection keychain (ignored on
            // iOS, where it is the only keychain).
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Every synced locked-notes key on this device. Empty when there are
    /// none or the keychain can't be queried (no iCloud Keychain, missing
    /// entitlement) — never throws, so callers fall back to local keys.
    nonisolated static func loadAll() -> [SymmetricKey] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.storage.error("LockedNoteSyncedKeyStore: keychain query failed (\(status))")
            }
            return []
        }
        let rows = (result as? [[String: Any]]) ?? []
        var keys: [SymmetricKey] = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(syncedAccountPrefix),
                  let data = row[kSecValueData as String] as? Data,
                  data.count == 32 else { continue }
            keys.append(SymmetricKey(data: data))
        }
        return LockedNoteKeySelection.unique(keys)
    }

    /// Publishes `key` to iCloud Keychain unless a synced copy with its id
    /// already exists. Best effort: returns whether it is (now) published.
    @discardableResult
    nonisolated static func publish(_ key: SymmetricKey) -> Bool {
        let account = LockedNoteKeySelection.syncedAccount(for: key)
        var add = baseQuery()
        add[kSecAttrAccount as String] = account
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrLabel as String] = "Scribe locked notes key"
        // Synchronizable items can't be ThisDeviceOnly.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            return true
        default:
            Log.storage.error("LockedNoteSyncedKeyStore: couldn't publish the key (\(status))")
            return false
        }
    }

    /// Creates a new random key and publishes it. Used by a device that has
    /// no key yet (the first note locked on iPhone / iPad). Throws when the
    /// keychain refuses the item.
    nonisolated static func createPublishedKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        guard publish(key) else { throw LockedNoteSyncedKeyStoreError.couldNotStoreKey }
        return key
    }
}

enum LockedNoteSyncedKeyStoreError: Error, LocalizedError {
    case couldNotStoreKey

    var errorDescription: String? {
        switch self {
        case .couldNotStoreKey:
            return "The Keychain couldn't store the locked-notes key."
        }
    }
}
