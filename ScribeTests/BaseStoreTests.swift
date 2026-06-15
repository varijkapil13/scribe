// ScribeTests/BaseStoreTests.swift
import XCTest
@testable import Scribe

/// Tests for the pure Bases query layer: filter clauses, sorting, and
/// grouping over ``BaseRecord`` collections. No database / filesystem — the
/// logic operates on in-memory records.
final class BaseStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func record(_ title: String, _ props: [String: PropertyValue]) -> BaseRecord {
        let note = Note(title: title)
        let properties = props.map { NoteProperty(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        return BaseRecord(note: note, properties: properties)
    }

    private var fixtures: [BaseRecord] {
        [
            record("Alpha", ["status": .select("Todo"), "priority": .number(3), "starred": .checkbox(true)]),
            record("Bravo", ["status": .select("Done"), "priority": .number(1), "starred": .checkbox(false)]),
            record("Charlie", ["status": .select("Todo"), "priority": .number(2), "starred": .checkbox(true)]),
            record("Delta", ["priority": .number(5)]),  // no status
        ]
    }

    // MARK: - Filtering

    func testEqualsFilter() {
        let clause = FilterClause(key: "status", op: .equals, operand: "Todo")
        let query = BaseQuery(filters: [clause])
        let titles = query.apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(Set(titles), ["Alpha", "Charlie"])
    }

    func testContainsFilterCaseInsensitive() {
        let clause = FilterClause(key: "status", op: .contains, operand: "do")
        let titles = BaseQuery(filters: [clause]).apply(to: fixtures).map(\.note.title)
        // "Todo" and "Done" both contain "do" (case-insensitive).
        XCTAssertEqual(Set(titles), ["Alpha", "Charlie", "Bravo"])
    }

    func testNumberGreaterThanFilter() {
        let clause = FilterClause(key: "priority", op: .greaterThan, operand: "2")
        let titles = BaseQuery(filters: [clause]).apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(Set(titles), ["Alpha", "Delta"])  // 3 and 5
    }

    func testCheckboxFilter() {
        let clause = FilterClause(key: "starred", op: .isTrue)
        let titles = BaseQuery(filters: [clause]).apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(Set(titles), ["Alpha", "Charlie"])
    }

    func testIsEmptyFilter() {
        let clause = FilterClause(key: "status", op: .isEmpty)
        let titles = BaseQuery(filters: [clause]).apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(titles, ["Delta"])
    }

    func testMultipleFiltersAreAnded() {
        let query = BaseQuery(filters: [
            FilterClause(key: "status", op: .equals, operand: "Todo"),
            FilterClause(key: "starred", op: .isTrue),
            FilterClause(key: "priority", op: .lessThan, operand: "3"),
        ])
        let titles = query.apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(titles, ["Charlie"])  // Todo + starred + priority 2 < 3
    }

    func testBuiltInTitleFilter() {
        let clause = FilterClause(key: "title", op: .contains, operand: "alph")
        let titles = BaseQuery(filters: [clause]).apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(titles, ["Alpha"])
    }

    // MARK: - Sorting

    func testSortByNumberAscending() {
        let query = BaseQuery(sort: SortDescriptor(key: "priority", ascending: true))
        let titles = query.apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(titles, ["Bravo", "Charlie", "Alpha", "Delta"])  // 1,2,3,5
    }

    func testSortByNumberDescending() {
        let query = BaseQuery(sort: SortDescriptor(key: "priority", ascending: false))
        let titles = query.apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(titles, ["Delta", "Alpha", "Charlie", "Bravo"])  // 5,3,2,1
    }

    func testSortMissingKeySortsLast() {
        // Delta has no status; it should land last regardless of direction.
        let asc = BaseQuery(sort: SortDescriptor(key: "status", ascending: true))
            .apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(asc.last, "Delta")
        let desc = BaseQuery(sort: SortDescriptor(key: "status", ascending: false))
            .apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(desc.last, "Delta")
    }

    func testSortByTitle() {
        let query = BaseQuery(sort: SortDescriptor(key: "title", ascending: true))
        let titles = query.apply(to: fixtures).map(\.note.title)
        XCTAssertEqual(titles, ["Alpha", "Bravo", "Charlie", "Delta"])
    }

    // MARK: - Grouping

    func testGroupByStatus() {
        let query = BaseQuery(groupBy: "status")
        let groups = query.grouped(fixtures)
        // Done, Todo (alphabetical), then the "no value" bucket last.
        XCTAssertEqual(groups.map(\.key), ["Done", "Todo", nil])
        XCTAssertEqual(groups.first { $0.key == "Todo" }?.records.count, 2)
        XCTAssertEqual(groups.last?.title, "No value")
        XCTAssertEqual(groups.last?.records.map(\.note.title), ["Delta"])
    }

    func testGroupWithoutKeyYieldsSingleGroup() {
        let groups = BaseQuery().grouped(fixtures)
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?.key)
        XCTAssertEqual(groups.first?.records.count, fixtures.count)
    }

    func testGroupHonorsFilterAndSort() {
        let query = BaseQuery(
            filters: [FilterClause(key: "starred", op: .isTrue)],
            sort: SortDescriptor(key: "priority", ascending: true),
            groupBy: "status"
        )
        let groups = query.grouped(fixtures)
        // Only Alpha + Charlie (both Todo, both starred), sorted by priority.
        XCTAssertEqual(groups.map(\.key), ["Todo"])
        XCTAssertEqual(groups.first?.records.map(\.note.title), ["Charlie", "Alpha"])  // 2, 3
    }

    // MARK: - Column discovery

    func testDiscoveredPropertyKeys() {
        let keys = fixtures.discoveredPropertyKeys()
        XCTAssertEqual(Set(keys), ["priority", "starred", "status"])
    }

    func testDistinctValues() {
        XCTAssertEqual(fixtures.distinctValues(forKey: "status"), ["Done", "Todo"])
    }
}
