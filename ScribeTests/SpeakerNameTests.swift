import XCTest
import GRDB
@testable import Scribe

/// Speaker naming: the pure resolver, the v18 migration + store round-trip,
/// and display names in exports.
@MainActor
final class SpeakerNameTests: XCTestCase {

    // MARK: - Resolver

    func testBuiltInDefaults() {
        let resolver = SpeakerNameResolver()
        XCTAssertEqual(resolver.displayName(forKey: "you"), "You")
        XCTAssertEqual(resolver.displayName(forKey: "REMOTE"), "Remote")
        XCTAssertEqual(resolver.displayName(forKey: "Priya"), "Priya")
        XCTAssertEqual(resolver.displayName(forKey: ""), "Unknown")
    }

    func testGlobalYouNameAndSessionRenames() {
        let resolver = SpeakerNameResolver(sessionNames: ["remote": "Priya"], defaultYouName: "Varij")
        XCTAssertEqual(resolver.displayName(forKey: "you"), "Varij")
        XCTAssertEqual(resolver.displayName(forKey: "remote"), "Priya")

        let renamedYou = SpeakerNameResolver(sessionNames: ["you": "Host"], defaultYouName: "Varij")
        XCTAssertEqual(renamedYou.displayName(forKey: "you"), "Host", "session name beats global default")

        let blank = SpeakerNameResolver(sessionNames: ["remote": "  "], defaultYouName: "  ")
        XCTAssertEqual(blank.displayName(forKey: "remote"), "Remote")
        XCTAssertEqual(blank.displayName(forKey: "you"), "You")
    }

    func testOverrideTakesPrecedenceOverSource() {
        let resolver = SpeakerNameResolver(sessionNames: ["remote": "Priya", "Sam": "Sam K."])
        let reassigned = Segment(sessionId: "s", startMs: 0, endMs: 1, speaker: "remote", text: "hi",
                                 speakerOverride: "Sam")
        let toYou = Segment(sessionId: "s", startMs: 0, endMs: 1, speaker: "remote", text: "hi",
                            speakerOverride: "You")
        let plain = Segment(sessionId: "s", startMs: 0, endMs: 1, speaker: "remote", text: "hi")
        XCTAssertEqual(resolver.displayName(for: reassigned), "Sam K.")
        XCTAssertEqual(SpeakerNameResolver.effectiveKey(for: toYou), "you")
        XCTAssertEqual(resolver.displayName(for: toYou), "You")
        XCTAssertEqual(resolver.displayName(for: plain), "Priya")
        XCTAssertEqual(SpeakerNameResolver.effectiveKey(speaker: "you", override: "  "), "you")
    }

    func testAvailableKeysOrder() {
        let resolver = SpeakerNameResolver(sessionNames: ["Zoe": "Zoe", "remote": "Priya"])
        let segments = [
            Segment(sessionId: "s", startMs: 0, endMs: 1, speaker: "remote", text: "a", speakerOverride: "Sam"),
            Segment(sessionId: "s", startMs: 1, endMs: 2, speaker: "you", text: "b"),
        ]
        XCTAssertEqual(resolver.availableKeys(in: segments), ["you", "remote", "Sam", "Zoe"])
    }

    func testDefaultYouNamePreference() {
        let suite = "speaker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fallback = SpeakerNamePreferences.systemFullName() ?? "You"
        XCTAssertEqual(SpeakerNamePreferences.defaultYouName(defaults: defaults), fallback)
        defaults.set("  ", forKey: SpeakerNamePreferences.defaultYouNameKey)
        XCTAssertEqual(SpeakerNamePreferences.defaultYouName(defaults: defaults), fallback)
        defaults.set(" Varij ", forKey: SpeakerNamePreferences.defaultYouNameKey)
        XCTAssertEqual(SpeakerNamePreferences.defaultYouName(defaults: defaults), "Varij")
    }

    // MARK: - Migration + store

    private func makeStore() throws -> (DatabaseManager, TranscriptStore, Session) {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let store = TranscriptStore(databaseManager: dbm)
        let note = try notes.createNote(title: "Sync")
        let session = try store.createSession(title: "Sync", noteId: note.id)
        return (dbm, store, session)
    }

    func testMigrationCreatesSchema() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        try dbm.database.read { db in
            XCTAssertTrue(try db.tableExists("session_speakers"))
            let segmentColumns = try db.columns(in: "segments").map(\.name)
            XCTAssertTrue(segmentColumns.contains("speakerOverride"))
            let speakerColumns = Set(try db.columns(in: "session_speakers").map(\.name))
            XCTAssertEqual(speakerColumns, ["sessionId", "speakerKey", "displayName"])
            let applied = try DatabaseManager.makeMigrator().appliedMigrations(db)
            XCTAssertTrue(applied.contains("v18_speaker_names"))
        }
    }

    func testSpeakerNamesRoundTrip() throws {
        let (_, store, session) = try makeStore()
        XCTAssertEqual(try store.fetchSpeakerNames(sessionId: session.id), [:])

        try store.setSpeakerName("Priya", forKey: "remote", sessionId: session.id)
        try store.setSpeakerName("Host", forKey: "You", sessionId: session.id)
        XCTAssertEqual(try store.fetchSpeakerNames(sessionId: session.id), ["remote": "Priya", "you": "Host"])

        try store.setSpeakerName("Priya S.", forKey: "remote", sessionId: session.id)
        XCTAssertEqual(try store.fetchSpeakerNames(sessionId: session.id)["remote"], "Priya S.")

        try store.setSpeakerName("  ", forKey: "you", sessionId: session.id)
        XCTAssertEqual(try store.fetchSpeakerNames(sessionId: session.id), ["remote": "Priya S."])
        XCTAssertTrue(try store.hasCustomSpeakers(sessionId: session.id))
    }

    func testSegmentOverridesRoundTrip() throws {
        let (_, store, session) = try makeStore()
        let a = try store.addSegment(sessionId: session.id, startMs: 0, endMs: 10, speaker: "remote", text: "one")
        let b = try store.addSegment(sessionId: session.id, startMs: 10, endMs: 20, speaker: "remote", text: "two")
        XCTAssertFalse(try store.hasCustomSpeakers(sessionId: session.id))

        try store.setSpeakerOverride("Sam", forSegmentIds: [a.id!, b.id!])
        var fetched = try store.fetchSegments(sessionId: session.id)
        XCTAssertEqual(fetched.map(\.speakerOverride), ["Sam", "Sam"])
        XCTAssertTrue(try store.hasCustomSpeakers(sessionId: session.id))

        // Assigning back to the source key clears the override.
        try store.setSpeakerOverride("REMOTE", forSegmentIds: [a.id!])
        try store.setSpeakerOverride(nil, forSegmentIds: [])
        fetched = try store.fetchSegments(sessionId: session.id)
        XCTAssertEqual(fetched.map(\.speakerOverride), [nil, "Sam"])

        try store.setSpeakerOverride(nil, forSegmentIds: [b.id!])
        XCTAssertEqual(try store.fetchSegments(sessionId: session.id).map(\.speakerOverride), [nil, nil])
    }

    func testSpeakerNamesCascadeOnSessionDelete() throws {
        let (dbm, store, session) = try makeStore()
        try store.setSpeakerName("Priya", forKey: "remote", sessionId: session.id)
        try store.deleteSession(id: session.id)
        let count = try dbm.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_speakers") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Exports

    private func exportFixture() -> (Session, [Segment], SpeakerNameResolver) {
        let session = Session(id: "s1", title: "Sync", createdAt: Date(timeIntervalSince1970: 1_715_000_000),
                              durationSeconds: 60, language: "en-US")
        let segments = [
            Segment(sessionId: "s1", startMs: 0, endMs: 1_000, speaker: "you", text: "Hi."),
            Segment(sessionId: "s1", startMs: 1_000, endMs: 2_000, speaker: "remote", text: "Hello."),
            Segment(sessionId: "s1", startMs: 2_000, endMs: 3_000, speaker: "remote", text: "Me too.",
                    speakerOverride: "you"),
        ]
        let resolver = SpeakerNameResolver(sessionNames: ["remote": "Priya"], defaultYouName: "Varij")
        return (session, segments, resolver)
    }

    func testMarkdownAndPlainTextUseDisplayNames() {
        let (session, segments, resolver) = exportFixture()
        let md = ExportManager.export(session: session, segments: segments, format: .markdown, speakerNames: resolver)
        XCTAssertTrue(md.contains("**[00:00:00] Varij:**"))
        XCTAssertTrue(md.contains("**[00:00:01] Priya:**"))
        XCTAssertTrue(md.contains("**[00:00:02] Varij:**"), "reassigned segment starts a new Varij group")

        let txt = ExportManager.export(session: session, segments: segments, format: .plainText, speakerNames: resolver)
        XCTAssertTrue(txt.contains("[00:00:01] Priya: Hello."))
        XCTAssertTrue(txt.contains("[00:00:02] Varij: Me too."))

        let legacy = ExportManager.export(session: session, segments: segments, format: .plainText)
        XCTAssertTrue(legacy.contains("[00:00:01] remote: Hello."), "no resolver keeps raw labels")
    }

    func testJSONIncludesDisplayNameAndKey() throws {
        let (session, segments, resolver) = exportFixture()
        let json = ExportManager.export(session: session, segments: segments, format: .json, speakerNames: resolver)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let exported = try XCTUnwrap(object?["segments"] as? [[String: Any]])
        XCTAssertEqual(exported[1]["speaker"] as? String, "Priya")
        XCTAssertEqual(exported[1]["speaker_key"] as? String, "remote")
        XCTAssertEqual(exported[2]["speaker_key"] as? String, "you")

        let legacy = ExportManager.export(session: session, segments: segments, format: .json)
        XCTAssertFalse(legacy.contains("speaker_key"))
    }

    func testNoteExportListsSpeakersOnlyWhenNamed() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let store = TranscriptStore(databaseManager: dbm)
        let note = try notes.createNote(title: "Sync")
        let session = try store.createSession(title: "Call", noteId: note.id)
        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 1, speaker: "remote", text: "Hello")

        XCTAssertFalse(NoteMarkdownExporter.export(note: note, transcriptStore: store).contains("**Speakers:**"))

        try store.setSpeakerName("Priya", forKey: "remote", sessionId: session.id)
        XCTAssertTrue(NoteMarkdownExporter.export(note: note, transcriptStore: store).contains("**Speakers:** Priya"))
    }
}
