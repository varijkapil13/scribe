import XCTest
@testable import Scribe

/// The iOS task editor replays only its own edits onto the stored row, so
/// changes made elsewhere while it's open survive its autosave.
final class TaskEditMergeTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    func testUntouchedFieldsComeFromTheStoredRow() {
        let baseline = TodoTask(id: "t", title: "Water plants", dueAt: day, recurrenceRule: "FREQ=WEEKLY")
        var edited = baseline
        edited.title = "Water the plants"

        // Completed from the list meanwhile: the repeat advanced the due date.
        var current = baseline
        current.dueAt = day.addingTimeInterval(7 * 86_400)
        current.completedAt = nil
        current.isPinned = true

        let merged = TaskEditMerge.rebased(edited: edited, baseline: baseline, onto: current)
        XCTAssertEqual(merged.title, "Water the plants")
        XCTAssertEqual(merged.dueAt, current.dueAt)
        XCTAssertTrue(merged.isPinned)
    }

    func testCompletionElsewhereIsKept() {
        let baseline = TodoTask(id: "t", title: "Reply")
        var edited = baseline
        edited.notes = "Draft first"
        var current = baseline
        current.completedAt = day

        let merged = TaskEditMerge.rebased(edited: edited, baseline: baseline, onto: current)
        XCTAssertEqual(merged.completedAt, day)
        XCTAssertEqual(merged.notes, "Draft first")
    }

    func testEditorChangesWinIncludingClears() {
        let baseline = TodoTask(id: "t", title: "Plan", priority: .high, dueAt: day, remindAt: day,
                                recurrenceRule: "FREQ=DAILY", scheduleBucket: .today, estimatedMinutes: 30)
        var edited = baseline
        edited.priority = nil
        edited.dueAt = nil
        edited.recurrenceRule = nil
        edited.remindAt = nil
        edited.scheduleBucket = .someday
        edited.estimatedMinutes = nil
        edited.startAt = day
        edited.areaId = "a"
        var current = baseline
        current.projectId = nil
        current.title = "Plan (renamed elsewhere)"

        let merged = TaskEditMerge.rebased(edited: edited, baseline: baseline, onto: current)
        XCTAssertNil(merged.priority)
        XCTAssertNil(merged.dueAt)
        XCTAssertNil(merged.recurrenceRule)
        XCTAssertNil(merged.remindAt)
        XCTAssertEqual(merged.scheduleBucket, .someday)
        XCTAssertNil(merged.estimatedMinutes)
        XCTAssertEqual(merged.startAt, day)
        XCTAssertEqual(merged.areaId, "a")
        XCTAssertEqual(merged.title, "Plan (renamed elsewhere)")
    }

    func testNoEditsReturnsTheStoredRow() {
        let baseline = TodoTask(id: "t", title: "A")
        var current = baseline
        current.title = "B"
        current.sortOrder = 4
        XCTAssertEqual(TaskEditMerge.rebased(edited: baseline, baseline: baseline, onto: current), current)
    }
}
