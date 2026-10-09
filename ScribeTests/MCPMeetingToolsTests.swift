// ScribeTests/MCPMeetingToolsTests.swift
import XCTest
@testable import Scribe

@MainActor
final class MCPMeetingToolsTests: XCTestCase {

    func testToolsListIncludesMeetingAndPeopleTools() async throws {
        let response = await MCPHandler.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        for name in ["ask_meetings", "list_people", "get_person", "search_meetings"] {
            XCTAssertTrue(names.contains(name), "missing tool \(name)")
        }
        // Existing tools are still there.
        XCTAssertTrue(names.contains("create_task"))
        XCTAssertTrue(names.contains("get_transcript"))
    }

    func testNewToolSchemasDeclareRequiredArguments() throws {
        let byName = Dictionary(uniqueKeysWithValues: MCPMeetingTools.definitions.compactMap { def -> (String, [String: Any])? in
            guard let name = def["name"] as? String,
                  let schema = def["inputSchema"] as? [String: Any] else { return nil }
            return (name, schema)
        })
        XCTAssertEqual(byName["ask_meetings"]?["required"] as? [String], ["question"])
        XCTAssertEqual(byName["search_meetings"]?["required"] as? [String], ["query"])
        XCTAssertEqual(byName["get_person"]?["required"] as? [String], ["name"])
        XCTAssertNil(byName["list_people"]?["required"])
        let askProps = try XCTUnwrap(byName["ask_meetings"]?["properties"] as? [String: Any])
        XCTAssertNotNil(askProps["scope"])
    }

    func testScopeParsing() throws {
        XCTAssertEqual(try MCPMeetingTools.resolveScope(nil), .all)
        XCTAssertEqual(try MCPMeetingTools.resolveScope("all"), .all)
        XCTAssertEqual(try MCPMeetingTools.resolveScope("last_7_days"), .lastDays(7))
        XCTAssertEqual(try MCPMeetingTools.resolveScope("LAST_30_DAYS"), .lastDays(30))
        XCTAssertThrowsError(try MCPMeetingTools.resolveScope("yesterday-ish"))
    }

    func testMissingQuestionIsAToolError() async throws {
        let response = await MCPHandler.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "ask_meetings", "arguments": [String: Any]()] as [String: Any]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }
}
