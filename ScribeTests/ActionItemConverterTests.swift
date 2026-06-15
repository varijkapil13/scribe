import XCTest
@testable import Scribe

/// Pure-function tests for the action-item → task draft mapping. The
/// integration story (Convert button writes a TodoTask, sets source ids,
/// row flips to "Open task") is exercised in `TaskStoreTests` for the
/// store-side helpers and would-be UI tests for the row.
final class ActionItemConverterTests: XCTestCase {

    func testDraftMapsCoreFields() {
        let item = ActionItem(
            id: UUID(),
            description: "  Send report  ",
            assignee: "Alice",
            deadline: nil,
            priority: .high,
            sourceText: "Alice will send the Q3 report by Friday."
        )
        let draft = ActionItemConverter.draft(from: item, sessionId: "session-1", detector: nil)

        XCTAssertEqual(draft.title, "Send report")
        XCTAssertEqual(draft.priority, .high)
        XCTAssertEqual(draft.sourceSessionId, "session-1")
        XCTAssertEqual(draft.sourceActionItemId, item.id.uuidString)
        XCTAssertEqual(draft.tags, ["alice"])
        XCTAssertTrue(draft.notes.contains("Assignee: Alice"))
        XCTAssertTrue(draft.notes.contains("Source: \"Alice will send the Q3 report by Friday.\""))
        XCTAssertNil(draft.dueAt) // no deadline → no parsed date
        XCTAssertNil(draft.projectId) // no project context → Inbox (default)
    }

    func testDraftPropagatesSourceSessionAndProject() {
        let item = ActionItem(
            id: UUID(),
            description: "Draft the spec",
            assignee: nil,
            deadline: nil,
            priority: nil,
            sourceText: ""
        )
        let draft = ActionItemConverter.draft(
            from: item,
            sessionId: "session-42",
            projectId: "project-7",
            detector: nil
        )

        // Converted tasks carry their source meeting + project context instead
        // of silently landing in Inbox.
        XCTAssertEqual(draft.sourceSessionId, "session-42")
        XCTAssertEqual(draft.sourceActionItemId, item.id.uuidString)
        XCTAssertEqual(draft.projectId, "project-7")
    }

    func testDraftIncludesDeadlineNoteEvenWhenUnparseable() {
        let item = ActionItem(
            id: UUID(),
            description: "Schedule kickoff",
            assignee: nil,
            deadline: "soon-ish",
            priority: nil,
            sourceText: ""
        )
        let draft = ActionItemConverter.draft(from: item, sessionId: "s", detector: nil)
        XCTAssertTrue(draft.notes.contains("Deadline (mentioned): soon-ish"))
        XCTAssertTrue(draft.tags.isEmpty)
        XCTAssertNil(draft.priority)
    }

    func testPriorityMappingCoversEveryCase() {
        XCTAssertEqual(ActionItemConverter.mapPriority(.high),   .high)
        XCTAssertEqual(ActionItemConverter.mapPriority(.medium), .medium)
        XCTAssertEqual(ActionItemConverter.mapPriority(.low),    .low)
        XCTAssertNil(ActionItemConverter.mapPriority(nil))
    }

    func testDeadlineWithExplicitDateProducesDueAt() throws {
        // Use a precise absolute phrase so NSDataDetector returns a deterministic date.
        let item = ActionItem(
            id: UUID(),
            description: "Submit invoice",
            assignee: nil,
            deadline: "December 1, 2099",
            priority: nil,
            sourceText: ""
        )
        let detector = try XCTUnwrap(NSDataDetector.scribeDateDetector)
        let draft = ActionItemConverter.draft(
            from: item,
            sessionId: "s",
            now: Date(timeIntervalSince1970: 0),
            detector: detector
        )
        let due = try XCTUnwrap(draft.dueAt)
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: due)
        XCTAssertEqual(comps.year, 2099)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 1)
    }
}
