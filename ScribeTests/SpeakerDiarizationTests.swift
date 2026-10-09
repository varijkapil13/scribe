import XCTest
@testable import Scribe

/// Pins how a diarization result is mapped onto stored transcript segments
/// and how model name suggestions are validated. FluidAudio itself (Core ML
/// models, audio files) isn't exercised here.
@MainActor
final class SpeakerDiarizationTests: XCTestCase {

    typealias R = DiarizedSegmentRebuilder

    private func turn(_ id: String, _ start: Double, _ end: Double) -> R.Turn {
        R.Turn(speakerId: id, start: start, end: end)
    }

    // MARK: - Speaker lookup

    func testSpeakerPicksLargestOverlap() {
        let turns = [turn("A", 0, 2), turn("B", 2, 10)]
        XCTAssertEqual(R.speaker(forStartMs: 1_000, endMs: 6_000, turns: turns), "B")
        XCTAssertEqual(R.speaker(forStartMs: 0, endMs: 1_500, turns: turns), "A")
    }

    func testSpeakerFallsBackToNearbyTurnOnlyWithinTolerance() {
        let turns = [turn("A", 5, 8)]
        XCTAssertEqual(R.speaker(forStartMs: 4_200, endMs: 4_500, turns: turns), "A")
        XCTAssertNil(R.speaker(forStartMs: 1_000, endMs: 2_000, turns: turns))
    }

    // MARK: - Rebuilding

    func testSingleSpeakerLeavesTranscriptAlone() {
        let stored = [R.Stored(id: 1, startMs: 0, endMs: 4_000, text: "hello there")]
        let pieces = [R.Piece(startMs: 0, endMs: 4_000, text: "hello there")]
        XCTAssertEqual(R.changes(stored: stored, pieces: pieces, turns: [turn("A", 0, 4)]), [])
    }

    func testCoalescedSegmentIsSplitPerSpeakerRun() {
        let stored = [R.Stored(id: 7, startMs: 0, endMs: 9_000, text: "hi all thanks Priya sure")]
        let pieces = [
            R.Piece(startMs: 0, endMs: 2_000, text: "hi all"),
            R.Piece(startMs: 2_500, endMs: 5_000, text: "thanks Priya"),
            R.Piece(startMs: 6_000, endMs: 9_000, text: "sure"),
        ]
        let turns = [turn("spk_b", 0, 5.2), turn("spk_a", 5.8, 9.5)]

        XCTAssertEqual(R.changes(stored: stored, pieces: pieces, turns: turns), [
            .split(id: 7, parts: [
                R.Part(speakerKey: "Speaker 1", startMs: 0, endMs: 5_000, text: "hi all thanks Priya"),
                R.Part(speakerKey: "Speaker 2", startMs: 6_000, endMs: 9_000, text: "sure"),
            ])
        ])
    }

    func testSpeakersAreNumberedByFirstAppearance() {
        let stored = [
            R.Stored(id: 1, startMs: 0, endMs: 2_000, text: "first"),
            R.Stored(id: 2, startMs: 3_000, endMs: 5_000, text: "second"),
            R.Stored(id: 3, startMs: 6_000, endMs: 8_000, text: "third"),
        ]
        let pieces = [
            R.Piece(startMs: 0, endMs: 2_000, text: "first"),
            R.Piece(startMs: 3_000, endMs: 5_000, text: "second"),
            R.Piece(startMs: 6_000, endMs: 8_000, text: "third"),
        ]
        // Raw ids sort the "wrong" way on purpose.
        let turns = [turn("z", 0, 2), turn("a", 3, 5), turn("z", 6, 8)]
        XCTAssertEqual(R.changes(stored: stored, pieces: pieces, turns: turns), [
            .relabel(id: 1, speakerKey: "Speaker 1"),
            .relabel(id: 2, speakerKey: "Speaker 2"),
            .relabel(id: 3, speakerKey: "Speaker 1"),
        ])
    }

    func testEditedTextFallsBackToWholeSegmentOverlap() {
        // Text no longer matches the raw pieces (user edit): never split, just
        // label by dominant overlap.
        let stored = [
            R.Stored(id: 1, startMs: 0, endMs: 4_000, text: "edited by hand"),
            R.Stored(id: 2, startMs: 5_000, endMs: 8_000, text: "other"),
        ]
        let pieces = [
            R.Piece(startMs: 0, endMs: 1_000, text: "original"),
            R.Piece(startMs: 1_500, endMs: 4_000, text: "words"),
            R.Piece(startMs: 5_000, endMs: 8_000, text: "other"),
        ]
        let turns = [turn("A", 0, 1), turn("B", 1.2, 4), turn("C", 5, 8)]
        XCTAssertEqual(R.changes(stored: stored, pieces: pieces, turns: turns), [
            .relabel(id: 1, speakerKey: "Speaker 1"),
            .relabel(id: 2, speakerKey: "Speaker 2"),
        ])
    }

    func testNoTurnsMeansNoChanges() {
        let stored = [R.Stored(id: 1, startMs: 0, endMs: 1_000, text: "x")]
        XCTAssertEqual(R.changes(stored: stored, pieces: [], turns: []), [])
    }

    // MARK: - Store

    func testApplyDiarizationSplitsAndRelabelsButKeepsManualOverrides() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let store = TranscriptStore(databaseManager: dbm)
        let note = try notes.createNote(title: "N", body: "")
        let session = try store.createSession(title: "S", noteId: note.id)

        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 9_000, speaker: "remote", text: "hi all sure")
        try store.addSegment(sessionId: session.id, startMs: 10_000, endMs: 12_000, speaker: "remote", text: "ok")
        try store.addSegment(sessionId: session.id, startMs: 13_000, endMs: 14_000, speaker: "remote", text: "mine")
        let ids = try store.fetchSegments(sessionId: session.id).compactMap(\.id)
        try store.setSpeakerOverride("Priya", forSegmentIds: [ids[2]])

        let diarizable = try store.fetchDiarizableSegments(sessionId: session.id)
        XCTAssertEqual(diarizable.map(\.id), [ids[0], ids[1]], "manually reassigned segments are skipped")

        try store.applyDiarization([
            .split(id: ids[0], parts: [
                R.Part(speakerKey: "Speaker 1", startMs: 0, endMs: 4_000, text: "hi all"),
                R.Part(speakerKey: "Speaker 2", startMs: 5_000, endMs: 9_000, text: "sure"),
            ]),
            .relabel(id: ids[1], speakerKey: "Speaker 2"),
            .relabel(id: ids[2], speakerKey: "Speaker 1"),
        ], sessionId: session.id)

        let after = try store.fetchSegments(sessionId: session.id)
        XCTAssertEqual(after.map(\.text), ["hi all", "sure", "ok", "mine"])
        XCTAssertEqual(after.map(\.speakerOverride), ["Speaker 1", "Speaker 2", "Speaker 2", "Priya"])
        XCTAssertTrue(after.allSatisfy { $0.speaker == "remote" })
    }

    // MARK: - Name suggestions

    func testParseAcceptsAttendeesAndTranscriptNamesOnly() {
        let response = """
        Sure! {"Speaker 1": "priya patel", "Speaker 2": "Tom", "Speaker 3": "Gandalf", "Speaker 9": "Ana"}
        """
        let names = SpeakerNameSuggester.parse(
            response,
            speakerKeys: ["Speaker 1", "Speaker 2", "Speaker 3"],
            attendees: ["Priya Patel", "Ana Ruiz"],
            transcriptText: "Thanks Tom, over to you."
        )
        XCTAssertEqual(names, ["Speaker 1": "Priya Patel", "Speaker 2": "Tom"])
    }

    func testParseUsesEachNameOnceAndIgnoresNullsAndGarbage() {
        let names = SpeakerNameSuggester.parse(
            #"{"Speaker 1": "Ana Ruiz", "Speaker 2": "ana ruiz", "Speaker 3": null}"#,
            speakerKeys: ["Speaker 1", "Speaker 2", "Speaker 3"],
            attendees: ["Ana Ruiz"],
            transcriptText: ""
        )
        XCTAssertEqual(names, ["Speaker 1": "Ana Ruiz"])
        XCTAssertEqual(SpeakerNameSuggester.parse("no json here", speakerKeys: ["Speaker 1"], attendees: [], transcriptText: ""), [:])
    }

    func testTranscriptNameMustBeAWholeWord() {
        let names = SpeakerNameSuggester.parse(
            #"{"Speaker 1": "Al"}"#,
            speakerKeys: ["Speaker 1"],
            attendees: [],
            transcriptText: "Also, the algorithm is fine."
        )
        XCTAssertEqual(names, [:])
    }

    func testPromptRespectsBudget() {
        let lines = (0..<1_000).map { ("Speaker 1", "line \($0) with some words in it") }
        let prompt = SpeakerNameSuggester.buildPrompt(lines: lines, speakerKeys: ["Speaker 1"], attendees: [])
        XCTAssertLessThan(prompt.count, SpeakerNameSuggester.transcriptBudget + 500)
        XCTAssertTrue(prompt.contains("Attendees: (none)"))
    }
}
