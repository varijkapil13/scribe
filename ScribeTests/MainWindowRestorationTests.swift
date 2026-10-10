import SwiftUI
import XCTest
@testable import Scribe

/// Main-window state restoration: `MainSelection` / column visibility ⇄ the
/// strings kept in `@SceneStorage`.
final class MainWindowRestorationTests: XCTestCase {

    private func assertRoundTrip(_ selection: MainSelection, file: StaticString = #filePath, line: UInt = #line) {
        let encoded = MainSelectionCodec.encode(selection)
        XCTAssertEqual(MainSelectionCodec.decode(encoded), selection,
                       "round trip failed for \(encoded)", file: file, line: line)
    }

    func testEverySelectionRoundTrips() {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        let all: [MainSelection] = [
            .live, .today, .recordings, .taskCalendar, .bases, .ask, .people,
            .task("T-1"), .note("N-1"), .session("S-1"),
            .tasks(.inbox), .tasks(.today), .tasks(.upcoming), .tasks(.all), .tasks(.completed), .tasks(.someday), .tasks(.area("a")),
            .tasks(.project("P-1")), .tasks(.tag("errands")), .tasks(.dueOn(day)),
            .notes(.all), .notes(.inbox), .notes(.daily), .notes(.graph),
            .notes(.notebook("NB-1")), .notes(.tag("work")),
        ]
        for selection in all { assertRoundTrip(selection) }
    }

    func testPayloadsMayContainSlashes() {
        assertRoundTrip(.notes(.tag("area/work/q3")))
        assertRoundTrip(.tasks(.tag("home/garden")))
        assertRoundTrip(.note("a/b"))
    }

    func testEncodingIsStableAndReadable() {
        XCTAssertEqual(MainSelectionCodec.encode(MainSelection.today), "today")
        XCTAssertEqual(MainSelectionCodec.encode(.note("abc")), "note/abc")
        XCTAssertEqual(MainSelectionCodec.encode(.tasks(.project("p"))), "tasks/project/p")
        XCTAssertEqual(MainSelectionCodec.encode(.notes(.tag("x"))), "notes/tag/x")
    }

    func testMalformedStringsDecodeToNil() {
        for bad in ["", "nope", "note", "note/", "tasks", "tasks/bogus", "tasks/project/",
                    "tasks/dueOn/notanumber", "notes/notebook/", "today/extra", "live/x"] {
            XCTAssertNil(MainSelectionCodec.decode(bad), "\(bad) should not decode")
        }
    }

    func testRestorationSkipsLiveAndActiveRecording() {
        XCTAssertNil(MainSelectionCodec.restoredSelection(from: "live", isRecording: false),
                     "No session runs at launch, so the live view is never restored")
        XCTAssertNil(MainSelectionCodec.restoredSelection(from: "note/n1", isRecording: true),
                     "An active recording owns the initial destination")
        XCTAssertNil(MainSelectionCodec.restoredSelection(from: "", isRecording: false))
        XCTAssertEqual(MainSelectionCodec.restoredSelection(from: "note/n1", isRecording: false),
                       .note("n1"))
    }

    @MainActor
    func testColumnVisibilityCodec() {
        XCTAssertEqual(ColumnVisibilityCodec.encode(.detailOnly), "detailOnly")
        XCTAssertEqual(ColumnVisibilityCodec.encode(.all), "all")
        XCTAssertEqual(ColumnVisibilityCodec.decode("detailOnly"), .detailOnly)
        XCTAssertEqual(ColumnVisibilityCodec.decode("all"), .all)
        XCTAssertEqual(ColumnVisibilityCodec.decode("doubleColumn"), .all)
        XCTAssertNil(ColumnVisibilityCodec.decode(""))
        XCTAssertNil(ColumnVisibilityCodec.decode("garbage"))
    }
}
