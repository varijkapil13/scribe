// ScribeTests/LockedNoteKeySelectionTests.swift
import CryptoKit
import XCTest
@testable import Scribe

/// Cross-device locked notes: choosing among the local + iCloud-Keychain keys.
final class LockedNoteKeySelectionTests: XCTestCase {

    func testPicksTheKeyThatSealedTheEnvelope() throws {
        let mac = SymmetricKey(size: .bits256)
        let phone = SymmetricKey(size: .bits256)
        let sealed = try LockedNoteEnvelope.seal("secret", key: phone)

        let chosen = try XCTUnwrap(LockedNoteKeySelection.key(for: sealed, among: [mac, phone]))
        XCTAssertEqual(LockedNoteEnvelope.keyIdentifier(for: chosen), LockedNoteEnvelope.keyIdentifier(for: phone))
        XCTAssertEqual(try LockedNoteEnvelope.open(sealed, key: chosen), "secret")
    }

    func testNoMatchOrNotAnEnvelope() throws {
        let sealed = try LockedNoteEnvelope.seal("x", key: SymmetricKey(size: .bits256))
        XCTAssertNil(LockedNoteKeySelection.key(for: sealed, among: [SymmetricKey(size: .bits256)]))
        XCTAssertNil(LockedNoteKeySelection.key(for: "plain text", among: [SymmetricKey(size: .bits256)]))
        XCTAssertNil(LockedNoteKeySelection.key(for: sealed, among: []))
    }

    func testPreferredSealingKeyIsDeterministic() throws {
        let keys = (0..<4).map { _ in SymmetricKey(size: .bits256) }
        let a = try XCTUnwrap(LockedNoteKeySelection.preferredSealingKey(keys))
        let b = try XCTUnwrap(LockedNoteKeySelection.preferredSealingKey(keys.reversed()))
        XCTAssertEqual(LockedNoteEnvelope.keyIdentifier(for: a), LockedNoteEnvelope.keyIdentifier(for: b))
        let smallest = keys.map(LockedNoteEnvelope.keyIdentifier(for:)).min()
        XCTAssertEqual(LockedNoteEnvelope.keyIdentifier(for: a), smallest)
        XCTAssertNil(LockedNoteKeySelection.preferredSealingKey([]))
    }

    func testSyncedAccountsAreKeyedById() {
        let key = SymmetricKey(size: .bits256)
        let account = LockedNoteKeySelection.syncedAccount(for: key)
        XCTAssertEqual(account, "synced-key-" + LockedNoteEnvelope.keyIdentifier(for: key))
        // Never the Mac's local item account.
        XCTAssertNotEqual(account, LockedNoteKeychain.account)
        XCTAssertEqual(LockedNoteSyncedKeyStore.service, LockedNoteKeychain.service)
    }

    func testUniqueDropsDuplicateKeys() {
        let key = SymmetricKey(size: .bits256)
        let copy = SymmetricKey(data: key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(LockedNoteKeySelection.unique([key, copy, SymmetricKey(size: .bits256)]).count, 2)
    }
}
