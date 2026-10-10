// ScribeTests/LockedNoteEnvelopeTests.swift
import CryptoKit
import XCTest
@testable import Scribe

final class LockedNoteEnvelopeTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)

    // MARK: - Round trip

    func testSealThenOpenRoundTrips() throws {
        let plaintext = "# Secret plan\n\n- [ ] buy a boat\n- [x] tell nobody\n"
        let sealed = try LockedNoteEnvelope.seal(plaintext, key: key)
        XCTAssertEqual(try LockedNoteEnvelope.open(sealed, key: key), plaintext)
    }

    func testRoundTripsUnicodeAndEmptyText() throws {
        for text in ["", "Grüße 👋 日本語 — “quotes”", String(repeating: "long line ", count: 2_000)] {
            let sealed = try LockedNoteEnvelope.seal(text, key: key)
            XCTAssertEqual(try LockedNoteEnvelope.open(sealed, key: key), text)
        }
    }

    func testArmorFormat() throws {
        let sealed = try LockedNoteEnvelope.seal("hello", key: key)
        let lines = sealed.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, LockedNoteEnvelope.beginMarker)
        XCTAssertEqual(lines.last, LockedNoteEnvelope.endMarker)
        XCTAssertTrue(lines.contains("Version: 1"))
        XCTAssertTrue(lines.contains("Key: \(LockedNoteEnvelope.keyIdentifier(for: key))"))
        XCTAssertFalse(sealed.contains("hello"), "plaintext must not appear in the envelope")
        for line in lines where !line.hasPrefix("-----") {
            XCTAssertLessThanOrEqual(line.count, LockedNoteEnvelope.lineWidth)
        }
    }

    func testEverySealUsesAFreshNonce() throws {
        let a = try LockedNoteEnvelope.seal("same text", key: key)
        let b = try LockedNoteEnvelope.seal("same text", key: key)
        XCTAssertNotEqual(a, b)
    }

    func testOpenToleratesCRLFAndTrailingContent() throws {
        let sealed = try LockedNoteEnvelope.seal("body", key: key)
        let crlf = "\n\n" + sealed.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\nsomething appended later"
        XCTAssertEqual(try LockedNoteEnvelope.open(crlf, key: key), "body")
    }

    // MARK: - Tamper detection

    func testTamperedCiphertextIsDetected() throws {
        let sealed = try LockedNoteEnvelope.seal("Do not change me", key: key)
        var lines = sealed.components(separatedBy: "\n")
        // First payload line (after the blank line following the headers).
        guard let blank = lines.firstIndex(of: "") else { return XCTFail("no header separator") }
        var payload = Array(lines[blank + 1])
        let index = payload.count / 2
        payload[index] = payload[index] == "A" ? "B" : "A"
        lines[blank + 1] = String(payload)
        let tampered = lines.joined(separator: "\n")
        XCTAssertThrowsError(try LockedNoteEnvelope.open(tampered, key: key)) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .tampered)
        }
    }

    func testTamperedHeaderIsDetected() throws {
        let sealed = try LockedNoteEnvelope.seal("text", key: key)
        let otherId = String(LockedNoteEnvelope.keyIdentifier(for: key).reversed())
        let forged = sealed.replacingOccurrences(
            of: "Key: \(LockedNoteEnvelope.keyIdentifier(for: key))",
            with: "Key: \(otherId)"
        )
        XCTAssertThrowsError(try LockedNoteEnvelope.open(forged, key: key))
        let newerVersion = sealed.replacingOccurrences(of: "Version: 1", with: "Version: 2")
        XCTAssertThrowsError(try LockedNoteEnvelope.open(newerVersion, key: key)) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .unsupportedVersion(2))
        }
    }

    func testWrongKeyIsReported() throws {
        let sealed = try LockedNoteEnvelope.seal("text", key: key)
        XCTAssertThrowsError(try LockedNoteEnvelope.open(sealed, key: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .wrongKey)
        }
    }

    func testTruncatedOrMalformedEnvelopes() throws {
        let sealed = try LockedNoteEnvelope.seal("text that is long enough to span lines", key: key)
        let noEnd = sealed.replacingOccurrences(of: LockedNoteEnvelope.endMarker, with: "")
        XCTAssertThrowsError(try LockedNoteEnvelope.open(noEnd, key: key)) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .malformed)
        }
        let noHeaders = [LockedNoteEnvelope.beginMarker, "", "AAAA", LockedNoteEnvelope.endMarker].joined(separator: "\n")
        XCTAssertThrowsError(try LockedNoteEnvelope.open(noHeaders, key: key)) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .malformed)
        }
        let keyId = LockedNoteEnvelope.keyIdentifier(for: key)
        let shortPayload = [LockedNoteEnvelope.beginMarker, "Version: 1", "Key: \(keyId)", "", "AAAA", LockedNoteEnvelope.endMarker]
            .joined(separator: "\n")
        XCTAssertThrowsError(try LockedNoteEnvelope.open(shortPayload, key: key)) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .malformed)
        }
        XCTAssertThrowsError(try LockedNoteEnvelope.open("just a normal note", key: key)) { error in
            XCTAssertEqual(error as? LockedNoteEnvelopeError, .notLocked)
        }
    }

    // MARK: - Detection

    func testIsLocked() throws {
        let sealed = try LockedNoteEnvelope.seal("x", key: key)
        XCTAssertTrue(LockedNoteEnvelope.isLocked(sealed))
        XCTAssertTrue(LockedNoteEnvelope.isLocked("\n  \n" + sealed))
        XCTAssertFalse(LockedNoteEnvelope.isLocked("# A note\n\n" + sealed))
        XCTAssertFalse(LockedNoteEnvelope.isLocked(""))
    }

    func testKeyIdentifierIsStableAndShort() {
        let id = LockedNoteEnvelope.keyIdentifier(for: key)
        XCTAssertEqual(id, LockedNoteEnvelope.keyIdentifier(for: key))
        XCTAssertEqual(id.count, 8)
        XCTAssertNotEqual(id, LockedNoteEnvelope.keyIdentifier(for: SymmetricKey(size: .bits256)))
    }

    // MARK: - Re-lock policy

    func testRelockPolicy() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(LockedNoteRelockPolicy.shouldLock(lastActivity: start, now: start.addingTimeInterval(299), idleMinutes: 5))
        XCTAssertTrue(LockedNoteRelockPolicy.shouldLock(lastActivity: start, now: start.addingTimeInterval(300), idleMinutes: 5))
        // Zero / negative settings fall back to one minute.
        XCTAssertTrue(LockedNoteRelockPolicy.shouldLock(lastActivity: start, now: start.addingTimeInterval(61), idleMinutes: 0))
    }
}

// MARK: - Storage + editor integration

@MainActor
final class LockedNoteIntegrationTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!
    private var tasks: TaskStore!
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        dbm = try DatabaseManager(path: ":memory:")
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        notes = NoteStore(databaseManager: dbm, fileStore: NoteFileStore(directory: NotesDirectory(root: tempRoot)))
        transcripts = TranscriptStore(databaseManager: dbm)
        tasks = TaskStore(databaseManager: dbm)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        notes = nil
        transcripts = nil
        tasks = nil
        dbm = nil
        try await super.tearDown()
    }

    private func makeVM(_ note: Note) -> NoteDetailViewModel {
        NoteDetailViewModel(note: note, store: notes, transcriptStore: transcripts, taskStore: tasks, onNavigate: { _ in })
    }

    func testLockedBodyIsExcludedFromSearchAndPreview() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try LockedNoteEnvelope.seal("the zeppelin code is 4711", key: key)
        let created = try notes.createNote(title: "Vault Combination", body: sealed)

        let row = try XCTUnwrap(try notes.fetchAllNotes().first { $0.id == created.id })
        XCTAssertEqual(row.bodyExcerpt, LockedNoteEnvelope.excerptPlaceholder)
        XCTAssertTrue(try notes.searchNotes(query: "zeppelin").isEmpty)
        // Ciphertext never matches either.
        XCTAssertTrue(try notes.searchNotes(query: "BEGIN").isEmpty)
        // The clear title still finds the note.
        XCTAssertEqual(try notes.searchNotes(query: "combination").map(\.id), [created.id])
    }

    func testEditorSealsOnSaveAndDropsPlaintextOnRelock() throws {
        let created = try notes.createNote(title: "Diary", body: "dear diary, the password is hunter2")
        let vm = makeVM(created)
        XCTAssertEqual(vm.lockPhase, .notLocked)

        // What lockNote() does after authentication, without the Keychain.
        let key = SymmetricKey(size: .bits256)
        vm.lockState.key = key
        vm.lockPhase = .unlocked
        vm.markDirty()
        vm.save()
        vm.setLockedFrontmatterFlag(true)
        XCTAssertFalse(vm.isDirty)

        let entry = try XCTUnwrap(notes.diskEntry(forNoteId: created.id))
        XCTAssertTrue(LockedNoteEnvelope.isLocked(entry.file.body))
        XCTAssertFalse(entry.file.body.contains("hunter2"))
        XCTAssertEqual(entry.file.frontmatter.extraValue(forKey: "locked"), "true")
        XCTAssertEqual(entry.file.frontmatter.title, "Diary")
        XCTAssertEqual(try LockedNoteEnvelope.open(entry.file.body, key: key), "dear diary, the password is hunter2")
        XCTAssertTrue(try notes.searchNotes(query: "hunter2").isEmpty)
        // The plaintext stays in the editor while unlocked.
        XCTAssertEqual(vm.note.body, "dear diary, the password is hunter2")

        vm.relock()
        XCTAssertEqual(vm.lockPhase, .locked)
        XCTAssertNil(vm.lockState.key)
        XCTAssertTrue(LockedNoteEnvelope.isLocked(vm.note.body))
        XCTAssertFalse(vm.note.body.contains("hunter2"))

        // A fresh editor (no key in memory) opens the note locked.
        let reopened = makeVM(try XCTUnwrap(try notes.fetchNote(id: created.id)))
        XCTAssertEqual(reopened.lockPhase, .locked)

        // Title edits while locked keep the ciphertext.
        reopened.note.title = "Diary 2026"
        reopened.markDirty()
        reopened.save()
        let afterTitle = try XCTUnwrap(notes.diskEntry(forNoteId: created.id))
        XCTAssertEqual(afterTitle.file.frontmatter.title, "Diary 2026")
        XCTAssertEqual(try LockedNoteEnvelope.open(afterTitle.file.body, key: key), "dear diary, the password is hunter2")
    }

    func testRemoveLockWritesPlaintextAndClearsFlag() throws {
        let created = try notes.createNote(title: "Temp", body: "plain words")
        let vm = makeVM(created)
        vm.lockState.key = SymmetricKey(size: .bits256)
        vm.lockPhase = .unlocked
        vm.markDirty()
        vm.save()
        vm.setLockedFrontmatterFlag(true)

        vm.removeLock()
        XCTAssertEqual(vm.lockPhase, .notLocked)
        let entry = try XCTUnwrap(notes.diskEntry(forNoteId: created.id))
        XCTAssertEqual(entry.file.body, "plain words")
        XCTAssertNil(entry.file.frontmatter.extraValue(forKey: "locked"))
        XCTAssertEqual(try notes.searchNotes(query: "words").map(\.id), [created.id])
    }
}
