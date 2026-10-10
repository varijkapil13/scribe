import XCTest
@testable import Scribe

/// The portable rules behind the iPhone / iPad recorder: audio-session event
/// mapping and policy, the level meter scale, retained-audio lookup, titles,
/// live coalescing, the note recap and the shared import job.
final class MobileRecordingTests: XCTestCase {

    // MARK: - Audio session events

    func testRouteChangeReasonsMapFromRawValues() {
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 0), .unknown)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 1), .newDeviceAvailable)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 2), .oldDeviceUnavailable)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 3), .categoryChange)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 4), .routeOverride)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 5), .unknown)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 6), .wakeFromSleep)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 7), .noSuitableRouteForCategory)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 8), .routeConfigurationChange)
        XCTAssertEqual(MobileAudioRouteChange(rawReason: 99), .unknown)
    }

    func testInterruptionParsing() {
        XCTAssertEqual(MobileAudioInterruption(typeRaw: 1, optionsRaw: nil), .began)
        XCTAssertEqual(MobileAudioInterruption(typeRaw: 0, optionsRaw: 1), .ended(shouldResume: true))
        XCTAssertEqual(MobileAudioInterruption(typeRaw: 0, optionsRaw: 0), .ended(shouldResume: false))
        XCTAssertEqual(MobileAudioInterruption(typeRaw: 0, optionsRaw: nil), .ended(shouldResume: false))
        XCTAssertNil(MobileAudioInterruption(typeRaw: nil, optionsRaw: 1))
        XCTAssertNil(MobileAudioInterruption(typeRaw: 7, optionsRaw: nil))
    }

    func testCallPausesARunningRecordingOnly() {
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(
            for: .began, isCapturing: true, isPausedByUser: false, wasPausedByInterruption: false), .pause)
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(
            for: .began, isCapturing: false, isPausedByUser: true, wasPausedByInterruption: false), .ignore)
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(
            for: .began, isCapturing: false, isPausedByUser: false, wasPausedByInterruption: false), .ignore)
    }

    func testCallEndResumesOnlyWhatItPausedAndWhenAllowed() {
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(
            for: .ended(shouldResume: true), isCapturing: false, isPausedByUser: false, wasPausedByInterruption: true), .resume)
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(
            for: .ended(shouldResume: false), isCapturing: false, isPausedByUser: false, wasPausedByInterruption: true), .ignore)
        // The user paused before the call: stay paused.
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(
            for: .ended(shouldResume: true), isCapturing: false, isPausedByUser: true, wasPausedByInterruption: false), .ignore)
    }

    func testRouteChangesRestartInputOrPause() {
        for change in [MobileAudioRouteChange.newDeviceAvailable, .oldDeviceUnavailable, .routeOverride, .routeConfigurationChange] {
            XCTAssertEqual(MobileRecordingInterruptionPolicy.action(for: change, isCapturing: true), .restartInput, "\(change)")
            XCTAssertEqual(MobileRecordingInterruptionPolicy.action(for: change, isCapturing: false), .ignore, "\(change)")
        }
        XCTAssertEqual(MobileRecordingInterruptionPolicy.action(for: .noSuitableRouteForCategory, isCapturing: true), .pause)
        for change in [MobileAudioRouteChange.unknown, .categoryChange, .wakeFromSleep] {
            XCTAssertEqual(MobileRecordingInterruptionPolicy.action(for: change, isCapturing: true), .ignore, "\(change)")
        }
    }

    // MARK: - Level meter

    func testLevelScaleIsLogarithmicAndClamped() {
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: 0), 0)
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: -1), 0)
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: .nan), 0)
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: 4), 1, accuracy: 1e-9)
        // -50 dB is the floor; -25 dB is half way.
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: 0.003), 0)
        XCTAssertEqual(MobileAudioLevelScale.normalized(linearPeak: Float(pow(10.0, -25.0 / 20.0))), 0.5, accuracy: 1e-4)
    }

    func testLevelSmoothingRisesFasterThanItFalls() {
        let up = MobileAudioLevelScale.smoothed(previous: 0, next: 1)
        let down = 1 - MobileAudioLevelScale.smoothed(previous: 1, next: 0)
        XCTAssertGreaterThan(up, down)
        XCTAssertEqual(MobileAudioLevelScale.smoothed(previous: 0.4, next: 0.4), 0.4, accuracy: 1e-12)
    }

    // MARK: - Retained audio lookup

    func testAudioLocatorPrefersAnExistingStoredFolder() {
        let root = URL(fileURLWithPath: "/new/container/Audio", isDirectory: true)
        let stored = "/old/container/Audio/s1"
        let existing: Set<String> = [stored + "/mic.m4a"]
        let directory = SessionAudioLocator.directory(storedPath: stored, sessionId: "s1", currentRoot: root,
                                                      fileExists: { existing.contains($0) })
        XCTAssertEqual(directory?.path, stored)
    }

    func testAudioLocatorFallsBackToTheCurrentRoot() {
        let root = URL(fileURLWithPath: "/new/container/Audio", isDirectory: true)
        let existing: Set<String> = ["/new/container/Audio/s1/system.m4a"]
        let directory = SessionAudioLocator.directory(storedPath: "/old/container/Audio/s1", sessionId: "s1",
                                                      currentRoot: root, fileExists: { existing.contains($0) })
        XCTAssertEqual(directory?.path, "/new/container/Audio/s1")
        let file = directory.flatMap { SessionAudioLocator.playableFile(in: $0, fileExists: { existing.contains($0) }) }
        XCTAssertEqual(file?.lastPathComponent, "system.m4a")
    }

    func testAudioLocatorReturnsNilWithoutAudio() {
        let root = URL(fileURLWithPath: "/c/Audio", isDirectory: true)
        XCTAssertNil(SessionAudioLocator.directory(storedPath: nil, sessionId: "s1", currentRoot: root, fileExists: { _ in false }))
        XCTAssertNil(SessionAudioLocator.directory(storedPath: "", sessionId: "s1", currentRoot: root, fileExists: { _ in false }))
    }

    func testPlayableFilePrefersTheMicTrack() {
        let dir = URL(fileURLWithPath: "/a/s1", isDirectory: true)
        let both: Set<String> = ["/a/s1/mic.m4a", "/a/s1/system.m4a"]
        XCTAssertEqual(SessionAudioLocator.playableFile(in: dir, fileExists: { both.contains($0) })?.lastPathComponent, "mic.m4a")
    }

    // MARK: - Titles

    func testTitleUsesTheCalendarEvent() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let event = CalendarEventInfo(id: "e1", title: "Weekly Sync", start: date, end: date.addingTimeInterval(1_800))
        let title = MobileRecordingTitle.noteTitle(event: event, date: date,
                                                   locale: Locale(identifier: "en_US_POSIX"),
                                                   timeZone: TimeZone(identifier: "UTC") ?? .current)
        XCTAssertTrue(title.hasPrefix("Weekly Sync — "), title)
    }

    func testTitleFallsBackToInPersonMeeting() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let title = MobileRecordingTitle.noteTitle(event: nil, date: date,
                                                   locale: Locale(identifier: "en_US_POSIX"),
                                                   timeZone: TimeZone(identifier: "UTC") ?? .current)
        XCTAssertTrue(title.hasPrefix("In-person meeting on "), title)
        XCTAssertTrue(title.contains("2026"), title)
    }

    func testElapsedLabelAndRecordedOnLine() {
        XCTAssertEqual(MobileRecordingTitle.elapsedLabel(seconds: 0), "0:00")
        XCTAssertEqual(MobileRecordingTitle.elapsedLabel(seconds: 65.9), "1:05")
        XCTAssertEqual(MobileRecordingTitle.elapsedLabel(seconds: 3_723), "1:02:03")
        XCTAssertEqual(MobileRecordingTitle.elapsedLabel(seconds: -5), "0:00")
        XCTAssertEqual(MobileRecordingTitle.elapsedLabel(seconds: .infinity), "0:00")
        XCTAssertEqual(MobileRecordingTitle.recordedOnLine(deviceName: "iPad"),
                       "*Recorded on iPad — In-person / speakerphone.*")
        XCTAssertEqual(MobileRecordingTitle.recordedOnLine(deviceName: " "),
                       "*Recorded on iPhone or iPad — In-person / speakerphone.*")
    }

    // MARK: - Live coalescing

    private func piece(_ start: Int, _ end: Int, _ text: String, speaker: String = "In person") -> LiveTranscriptCoalescer.Piece {
        LiveTranscriptCoalescer.Piece(startMs: start, endMs: end, speaker: speaker, text: text)
    }

    func testLiveCoalescerMergesCloseResults() {
        var coalescer = LiveTranscriptCoalescer(maxSpanMs: 30_000, maxGapMs: 2_500)
        XCTAssertNil(coalescer.ingest(piece(0, 1_000, "Hello")))
        XCTAssertNil(coalescer.ingest(piece(1_500, 3_000, " everyone ")))
        XCTAssertEqual(coalescer.pending, piece(0, 3_000, "Hello everyone"))
    }

    func testLiveCoalescerClosesOnGapSpeakerAndSpan() {
        var coalescer = LiveTranscriptCoalescer(maxSpanMs: 10_000, maxGapMs: 2_000)
        _ = coalescer.ingest(piece(0, 1_000, "One"))
        // Gap of 3 s closes the paragraph.
        XCTAssertEqual(coalescer.ingest(piece(4_000, 5_000, "Two")), piece(0, 1_000, "One"))
        // A different speaker closes it too.
        XCTAssertEqual(coalescer.ingest(piece(5_200, 6_000, "Three", speaker: "Speaker")), piece(4_000, 5_000, "Two"))
        // Span: 5.2 s … 16 s would exceed 10 s.
        _ = coalescer.ingest(piece(6_100, 8_000, "more", speaker: "Speaker"))
        let closed = coalescer.ingest(piece(9_000, 16_000, "too long", speaker: "Speaker"))
        XCTAssertEqual(closed, piece(5_200, 8_000, "Three more", speaker: "Speaker"))
        XCTAssertEqual(coalescer.flush(), piece(9_000, 16_000, "too long", speaker: "Speaker"))
        XCTAssertNil(coalescer.flush())
    }

    func testLiveCoalescerIgnoresEmptyTextAndClosesWhenIdle() {
        var coalescer = LiveTranscriptCoalescer(maxSpanMs: 30_000, maxGapMs: 2_000)
        XCTAssertNil(coalescer.ingest(piece(0, 500, "   ")))
        XCTAssertNil(coalescer.pending)
        _ = coalescer.ingest(piece(0, 1_000, "Hi"))
        XCTAssertNil(coalescer.closeIfIdle(audioClockMs: 2_500))
        XCTAssertEqual(coalescer.closeIfIdle(audioClockMs: 3_500), piece(0, 1_000, "Hi"))
        XCTAssertNil(coalescer.pending)
    }

    // MARK: - Note recap

    private func actionItem(_ text: String, assignee: String? = nil, deadline: String? = nil) -> ActionItem {
        ActionItem(id: UUID(), description: text, assignee: assignee, deadline: deadline, priority: nil, sourceText: "")
    }

    func testSummaryMarkdownSections() {
        let summary = MeetingSummary(
            id: UUID(), sessionId: "s1", summary: "We agreed on the launch.",
            keyDecisions: ["Ship on the 14th", "  "],
            actionItems: [actionItem("Send the deck", assignee: "Priya", deadline: "Friday"), actionItem("  ")],
            keyTopics: ["Launch"], followUpQuestions: ["Budget?"], createdAt: Date()
        )
        let markdown = MeetingNoteRecap.summaryMarkdown(summary)
        XCTAssertTrue(markdown.hasPrefix("## Summary\n\nWe agreed on the launch."))
        XCTAssertTrue(markdown.contains("### Key decisions\n\n- Ship on the 14th"))
        XCTAssertFalse(markdown.contains("- \n"))
        XCTAssertTrue(markdown.contains("### Action items\n\n- [ ] Send the deck — Priya (due Friday)"))
        XCTAssertTrue(markdown.contains("### Open questions\n\n- Budget?"))
    }

    func testSummaryMarkdownOmitsEmptySections() {
        let summary = MeetingSummary(id: UUID(), sessionId: "s1", summary: "", keyDecisions: [], actionItems: [],
                                     keyTopics: [], followUpQuestions: [], createdAt: Date())
        XCTAssertEqual(MeetingNoteRecap.summaryMarkdown(summary), "## Summary\n\n_No summary._")
    }

    func testActionItemLine() {
        XCTAssertEqual(MeetingNoteRecap.actionItemLine(actionItem("Book  the room")), "- [ ] Book the room")
        XCTAssertNil(MeetingNoteRecap.actionItemLine(actionItem("")))
        XCTAssertEqual(MeetingNoteRecap.actionItemLine(actionItem("Call", assignee: " ", deadline: "tomorrow")),
                       "- [ ] Call (due tomorrow)")
    }

    func testTranscriptMarkdownOrdersAndLabelsSegments() {
        let segments = [
            Segment(id: 2, sessionId: "s1", startMs: 65_000, endMs: 70_000, speaker: "In person", text: "Second"),
            Segment(id: 1, sessionId: "s1", startMs: 0, endMs: 4_000, speaker: "In person", text: "First  line"),
            Segment(id: 3, sessionId: "s1", startMs: 80_000, endMs: 81_000, speaker: "In person", text: "  "),
        ]
        let markdown = MeetingNoteRecap.transcriptMarkdown(segments: segments, speakerName: { _ in "Priya" })
        XCTAssertEqual(markdown, "## Transcript\n\n**0:00 · Priya** First line\n\n**1:05 · Priya** Second")
        XCTAssertNil(MeetingNoteRecap.transcriptMarkdown(segments: [], speakerName: { _ in "" }))
    }

    func testApplyUpsertsBlocksAndKeepsUserText() {
        let body = "My own notes.\n"
        let once = MeetingNoteRecap.apply(to: body, sessionId: "s1", summary: "## Summary\n\nA",
                                          highlights: "## Highlights\n\n- **0:05** Marked moment",
                                          transcript: "## Transcript\n\nT")
        XCTAssertTrue(once.hasPrefix("My own notes."))
        XCTAssertEqual(NoteScribeBlocks.extractSummary(body: once, sessionId: "s1"), "## Summary\n\nA")
        XCTAssertEqual(NoteScribeBlocks.extract(body: once, kind: "highlights", id: "s1"), "## Highlights\n\n- **0:05** Marked moment")
        XCTAssertEqual(NoteScribeBlocks.extract(body: once, kind: MeetingNoteRecap.transcriptBlockKind, id: "s1"), "## Transcript\n\nT")

        // Re-running replaces in place; nil parts leave blocks alone.
        let twice = MeetingNoteRecap.apply(to: once, sessionId: "s1", summary: "## Summary\n\nB", highlights: nil, transcript: nil)
        XCTAssertEqual(NoteScribeBlocks.extractSummary(body: twice, sessionId: "s1"), "## Summary\n\nB")
        XCTAssertEqual(NoteScribeBlocks.extract(body: twice, kind: MeetingNoteRecap.transcriptBlockKind, id: "s1"), "## Transcript\n\nT")
        XCTAssertEqual(NoteScribeBlocks.blocks(in: twice).count, 3)
        XCTAssertEqual(NoteScribeBlocks.userContent(body: twice), "My own notes.")
        XCTAssertEqual(MeetingNoteRecap.apply(to: twice, sessionId: "s1", summary: nil, highlights: nil, transcript: nil), twice)
    }

    func testItemsToConvertSkipsConvertedEmptyAndDuplicates() {
        let done = actionItem("Already done")
        let first = actionItem("Send the deck")
        let duplicate = actionItem("send  the deck")
        let empty = actionItem(" ")
        let other = actionItem("Book the room")
        let result = MeetingNoteRecap.itemsToConvert([done, first, duplicate, empty, other],
                                                     convertedIds: [done.id.uuidString])
        XCTAssertEqual(result.map(\.id), [first.id, other.id])
    }

    func testRecapWriterUpdatesTheNoteOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-recap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbm = try DatabaseManager(path: ":memory:")
        let store = NoteStore(databaseManager: dbm, fileStore: NoteFileStore(directory: NotesDirectory(root: root)))
        let note = try store.createNote(title: "Meeting", body: "Agenda first.", tags: ["work"])
        let writer = MeetingNoteRecapWriter(noteStore: store)

        XCTAssertTrue(try writer.write(noteId: note.id, sessionId: "s1", summary: "## Summary\n\nDone.",
                                       highlights: nil, transcript: "## Transcript\n\n**0:00** Hi"))
        let saved = try XCTUnwrap(try store.fetchNote(id: note.id))
        XCTAssertTrue(saved.body.hasPrefix("Agenda first."))
        XCTAssertEqual(NoteScribeBlocks.extractSummary(body: saved.body, sessionId: "s1"), "## Summary\n\nDone.")
        XCTAssertEqual(try store.tags(for: note.id), ["work"])

        // Same content again: nothing to write.
        XCTAssertFalse(try writer.write(noteId: note.id, sessionId: "s1", summary: "## Summary\n\nDone.",
                                        highlights: nil, transcript: "## Transcript\n\n**0:00** Hi"))
        XCTAssertFalse(try writer.write(noteId: "missing", sessionId: "s1", summary: "x", highlights: nil, transcript: nil))
    }
}

/// The import job shared by the Mac and iPhone / iPad importers.
@MainActor
final class MediaImportTranscriptionJobTests: XCTestCase {

    private func makeJob() -> (MediaImportTranscriptionJob, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-job-\(UUID().uuidString)")
        let job = MediaImportTranscriptionJob(
            pipeline: TranscriptionPipeline(speaker: "remote"),
            recorder: SessionAudioRecorder(directory: directory)
        )
        return (job, directory)
    }

    private func segment(_ start: Int, _ end: Int, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(id: UUID(), sessionOffsetMs: start, startMs: start, endMs: end, speaker: "remote", text: text)
    }

    func testCollectsSegmentsAndMergesThem() {
        let (job, directory) = makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        var previews: [String] = []
        job.wire(onPreview: { previews.append($0) })
        job.pipeline.onSegment?(segment(0, 1_000, "Hello"))
        job.pipeline.onSegment?(segment(1_500, 2_000, "there"))
        job.pipeline.onSegment?(segment(20_000, 21_000, "Later"))

        XCTAssertEqual(job.segments.count, 3)
        XCTAssertEqual(job.transcribedMs, 21_000)
        XCTAssertEqual(previews, ["Hello", "there", "Later"])
        let merged = job.mergedPieces(speaker: nil)
        XCTAssertEqual(merged.map(\.text), ["Hello there", "Later"])
        XCTAssertEqual(merged.map(\.speaker), ["remote", "remote"])
        XCTAssertEqual(job.mergedPieces(speaker: "Speaker").map(\.speaker), ["Speaker", "Speaker"])
    }

    func testFeedCountsFramesAndRecordsErrors() throws {
        let (job, directory) = makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        job.wire(onPreview: { _ in })
        let buffer = try XCTUnwrap(MediaImportDecoder.makeBuffer([Float](repeating: 0, count: 8_000)))
        job.feed(buffer, frames: 8_000)
        job.feed(buffer, frames: 8_000)
        XCTAssertEqual(job.fedFrames, 16_000)
        XCTAssertEqual(job.fedMs, 1_000)
        XCTAssertNil(job.error)
        job.pipeline.onError?(ScribeMediaImportError.nothingTranscribed)
        XCTAssertNotNil(job.error)
        job.recorder.finish()
    }
}
