import XCTest
@testable import Scribe

/// Pure helpers behind `SpotlightIndexer`: identifier format/parse, record
/// mapping and pass planning.
final class SpotlightIndexPlannerTests: XCTestCase {

    // MARK: - SpotlightItemID

    func testUniqueIdentifierFormat() {
        XCTAssertEqual(SpotlightItemID.note("abc").uniqueIdentifier, "note:abc")
        XCTAssertEqual(SpotlightItemID.task("42").uniqueIdentifier, "task:42")
    }

    func testUniqueIdentifierRoundTrips() {
        for item in [SpotlightItemID.note("A-1"), .task("B-2"), .note("with:colon")] {
            XCTAssertEqual(SpotlightItemID(uniqueIdentifier: item.uniqueIdentifier), item)
        }
    }

    func testParseRejectsUnknownOrEmpty() {
        XCTAssertNil(SpotlightItemID(uniqueIdentifier: ""))
        XCTAssertNil(SpotlightItemID(uniqueIdentifier: "note:"))
        XCTAssertNil(SpotlightItemID(uniqueIdentifier: "task:"))
        XCTAssertNil(SpotlightItemID(uniqueIdentifier: "session:1"))
        XCTAssertNil(SpotlightItemID(uniqueIdentifier: "Note:1"))
        XCTAssertNil(SpotlightItemID(uniqueIdentifier: "abc"))
    }

    func testDomainsAndSelection() {
        XCTAssertEqual(SpotlightItemID.note("n").domainIdentifier, SpotlightItemID.noteDomain)
        XCTAssertEqual(SpotlightItemID.task("t").domainIdentifier, SpotlightItemID.taskDomain)
        XCTAssertNotEqual(SpotlightItemID.noteDomain, SpotlightItemID.taskDomain)
        XCTAssertEqual(SpotlightItemID.note("n").selection, .note("n"))
        XCTAssertEqual(SpotlightItemID.task("t").selection, .task("t"))
    }

    // MARK: - Records

    func testNoteRecordUsesExcerptAndFallbackTitle() {
        let date = Date(timeIntervalSince1970: 1_000)
        let note = Note(id: "n1", title: "  ", updatedAt: date, bodyExcerpt: "Hello")
        let record = SpotlightIndexPlanner.noteRecord(for: note)
        XCTAssertEqual(record.itemID, .note("n1"))
        XCTAssertEqual(record.title, "Untitled")
        XCTAssertEqual(record.detail, "Hello")
        XCTAssertEqual(record.modifiedAt, date)
    }

    func testTaskRecordSkipsCompletedAndCancelled() {
        XCTAssertNotNil(SpotlightIndexPlanner.taskRecord(for: TodoTask(title: "Open")))
        XCTAssertNil(SpotlightIndexPlanner.taskRecord(for: TodoTask(title: "Done", completedAt: Date())))
        XCTAssertNil(SpotlightIndexPlanner.taskRecord(for: TodoTask(title: "Won't", cancelledAt: Date())))
    }

    func testTaskRecordDetailIncludesNotes() {
        let record = SpotlightIndexPlanner.taskRecord(for: TodoTask(id: "t1", title: "Call", notes: " Bring docs "))
        XCTAssertEqual(record?.itemID, .task("t1"))
        XCTAssertEqual(record?.detail, "Bring docs")
        XCTAssertNil(SpotlightIndexPlanner.taskRecord(for: TodoTask(title: "Bare"))?.detail)
    }

    // MARK: - Throttle

    func testFullReindexThrottle() {
        let now = Date(timeIntervalSince1970: 100_000)
        let day: TimeInterval = 86_400
        XCTAssertTrue(SpotlightIndexPlanner.shouldFullReindex(lastFullReindex: nil, now: now, minimumInterval: day))
        XCTAssertFalse(SpotlightIndexPlanner.shouldFullReindex(lastFullReindex: now.addingTimeInterval(-60), now: now, minimumInterval: day))
        XCTAssertTrue(SpotlightIndexPlanner.shouldFullReindex(lastFullReindex: now.addingTimeInterval(-day), now: now, minimumInterval: day))
        // A last run "in the future" (clock moved back) doesn't block forever.
        XCTAssertTrue(SpotlightIndexPlanner.shouldFullReindex(lastFullReindex: now.addingTimeInterval(60), now: now, minimumInterval: day))
    }

    // MARK: - Planning

    private func record(_ item: SpotlightItemID, _ title: String, at seconds: TimeInterval) -> SpotlightRecord {
        SpotlightRecord(itemID: item, title: title, detail: nil, modifiedAt: Date(timeIntervalSince1970: seconds))
    }

    func testFullPlanWipesAndIndexesEverything() {
        let current = [record(.note("a"), "A", at: 1), record(.task("b"), "B", at: 2)]
        let plan = SpotlightIndexPlanner.plan(previous: ["x": record(.note("x"), "X", at: 0)], current: current, fullReindex: true, lastPass: nil)
        XCTAssertTrue(plan.deleteAllFirst)
        XCTAssertEqual(plan.upserts, current)
        XCTAssertEqual(plan.removals, [])
    }

    func testFirstPassIndexesOnlyChangesSinceLastPass() {
        let old = record(.note("old"), "Old", at: 10)
        let fresh = record(.note("new"), "New", at: 30)
        let plan = SpotlightIndexPlanner.plan(previous: nil, current: [old, fresh], fullReindex: false, lastPass: Date(timeIntervalSince1970: 20))
        XCTAssertFalse(plan.deleteAllFirst)
        XCTAssertEqual(plan.upserts, [fresh])
        XCTAssertEqual(plan.removals, [])
    }

    func testFirstPassWithoutHistoryIndexesEverything() {
        let current = [record(.note("a"), "A", at: 1)]
        let plan = SpotlightIndexPlanner.plan(previous: nil, current: current, fullReindex: false, lastPass: nil)
        XCTAssertEqual(plan.upserts, current)
    }

    func testDiffUpsertsChangedAndRemovesVanished() {
        let unchanged = record(.note("same"), "Same", at: 1)
        let before = record(.task("edit"), "Before", at: 1)
        let after = record(.task("edit"), "After", at: 2)
        let added = record(.note("added"), "Added", at: 3)
        let gone = record(.note("gone"), "Gone", at: 1)
        let previous = SpotlightIndexPlanner.snapshot(of: [unchanged, before, gone])

        let plan = SpotlightIndexPlanner.plan(previous: previous, current: [unchanged, after, added], fullReindex: false, lastPass: nil)
        XCTAssertFalse(plan.deleteAllFirst)
        XCTAssertEqual(plan.upserts, [after, added])
        XCTAssertEqual(plan.removals, ["note:gone"])
    }

    func testNoChangesMeansEmptyPlan() {
        let records = [record(.note("a"), "A", at: 1)]
        let plan = SpotlightIndexPlanner.plan(previous: SpotlightIndexPlanner.snapshot(of: records), current: records, fullReindex: false, lastPass: nil)
        XCTAssertTrue(plan.isEmpty)
    }

    func testSnapshotKeepsFirstDuplicate() {
        let first = record(.note("a"), "First", at: 1)
        let second = record(.note("a"), "Second", at: 2)
        XCTAssertEqual(SpotlightIndexPlanner.snapshot(of: [first, second])["note:a"], first)
    }
}
