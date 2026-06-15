// ScribeTests/BaseDefinitionStoreTests.swift
import XCTest
@testable import Scribe

/// Tests for the persisted Bases layer: ``BaseDefinition`` JSON round-tripping
/// and the file-backed CRUD store (``BaseDefinitionStore``) against a temp
/// vault root — no database, no app singletons.
final class BaseDefinitionStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BaseDefinitionStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = BaseDefinitionStore(vaultRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Codable round-trip

    func testDefinitionEncodeDecodeRoundTrips() throws {
        let original = BaseDefinition(
            id: UUID(),
            name: "Tasks by status",
            query: BaseQuery(
                filters: [
                    FilterClause(key: "status", op: .equals, operand: "Todo"),
                    FilterClause(key: "starred", op: .isTrue),
                ],
                sort: BaseSort(key: "priority", ascending: false),
                groupBy: "status"
            ),
            layout: .board,
            columns: ["status", "priority", "due"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BaseDefinition.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.query.filters.count, 2)
        XCTAssertEqual(decoded.query.sort, BaseSort(key: "priority", ascending: false))
        XCTAssertEqual(decoded.query.groupBy, "status")
        XCTAssertEqual(decoded.layout, .board)
        XCTAssertEqual(decoded.columns, ["status", "priority", "due"])
    }

    func testDecodeTolerateMissingFields() throws {
        // Only id + name present — every other field should default.
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Minimal"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BaseDefinition.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Minimal")
        XCTAssertEqual(decoded.layout, .table)
        XCTAssertTrue(decoded.columns.isEmpty)
        XCTAssertTrue(decoded.query.filters.isEmpty)
        XCTAssertNil(decoded.query.sort)
    }

    // MARK: - CRUD

    func testListEmptyWhenNoDirectory() throws {
        XCTAssertEqual(try store.list().count, 0)
    }

    func testCreateThenList() throws {
        let created = try store.create(name: "My Base")
        XCTAssertEqual(created.name, "My Base")

        let all = try store.list()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, created.id)
    }

    func testCreateBlankNameFallsBack() throws {
        let created = try store.create(name: "   ")
        XCTAssertEqual(created.name, "New Base")
    }

    func testSaveOverwritesAndBumpsUpdatedAt() throws {
        var def = try store.create(name: "Base")
        let firstUpdated = def.updatedAt

        def.query.groupBy = "status"
        // Ensure a measurable time delta.
        Thread.sleep(forTimeInterval: 0.01)
        let saved = try store.save(def)

        XCTAssertEqual(saved.query.groupBy, "status")
        XCTAssertGreaterThanOrEqual(saved.updatedAt, firstUpdated)

        let reloaded = store.load(id: def.id)
        XCTAssertEqual(reloaded?.query.groupBy, "status")

        // Still a single file — save overwrote rather than appended.
        XCTAssertEqual(try store.list().count, 1)
    }

    func testRename() throws {
        let created = try store.create(name: "Old Name")
        let renamed = try store.rename(id: created.id, to: "New Name")
        XCTAssertEqual(renamed?.name, "New Name")
        XCTAssertEqual(store.load(id: created.id)?.name, "New Name")
    }

    func testRenameMissingReturnsNil() throws {
        XCTAssertNil(try store.rename(id: UUID(), to: "Nope"))
    }

    func testDelete() throws {
        let a = try store.create(name: "A")
        let b = try store.create(name: "B")
        XCTAssertEqual(try store.list().count, 2)

        try store.delete(id: a.id)
        let remaining = try store.list()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, b.id)
        XCTAssertNil(store.load(id: a.id))
    }

    func testDeleteMissingIsNoOp() throws {
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    func testListOrderedByCreationTime() throws {
        let first = try store.create(name: "Zeta")   // created earlier
        Thread.sleep(forTimeInterval: 0.01)
        let second = try store.create(name: "Alpha") // created later

        let ordered = try store.list().map(\.id)
        XCTAssertEqual(ordered, [first.id, second.id])
    }

    func testStoredAsJSONUnderScribeBasesFolder() throws {
        let created = try store.create(name: "Base")
        let expected = tempRoot
            .appendingPathComponent(".scribe", isDirectory: true)
            .appendingPathComponent("bases", isDirectory: true)
            .appendingPathComponent("\(created.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }
}
