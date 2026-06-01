// ScribeTests/NavigationCoordinatorTests.swift
import XCTest
@testable import Scribe

@MainActor
final class NavigationCoordinatorTests: XCTestCase {

    func testStartsAtGivenDestinationWithNoHistory() {
        let nav = NavigationCoordinator(current: .today)
        XCTAssertEqual(nav.current, .today)
        XCTAssertFalse(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)
    }

    func testNavigatePushesBackAndClearsForward() {
        let nav = NavigationCoordinator(current: .today)
        nav.navigate(to: .tasks(.inbox))
        nav.navigate(to: .note("n1"))

        XCTAssertEqual(nav.current, .note("n1"))
        XCTAssertTrue(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)

        nav.goBack()
        XCTAssertEqual(nav.current, .tasks(.inbox))
        XCTAssertTrue(nav.canGoForward)

        // Navigating after a Back clears the forward stack (browser semantics).
        nav.navigate(to: .notes(.all))
        XCTAssertFalse(nav.canGoForward)
        XCTAssertEqual(nav.current, .notes(.all))
    }

    func testBackForwardRoundTrip() {
        let nav = NavigationCoordinator(current: .today)
        nav.navigate(to: .tasks(.inbox))
        nav.navigate(to: .note("n1"))

        nav.goBack()
        nav.goBack()
        XCTAssertEqual(nav.current, .today)
        XCTAssertFalse(nav.canGoBack)

        nav.goForward()
        XCTAssertEqual(nav.current, .tasks(.inbox))
        nav.goForward()
        XCTAssertEqual(nav.current, .note("n1"))
        XCTAssertFalse(nav.canGoForward)
    }

    func testNavigateToCurrentIsNoOp() {
        let nav = NavigationCoordinator(current: .today)
        nav.navigate(to: .today)
        XCTAssertFalse(nav.canGoBack, "re-selecting the current destination must not push history")
    }

    func testSelectIgnoresNil() {
        let nav = NavigationCoordinator(current: .today)
        nav.navigate(to: .tasks(.inbox))
        nav.select(nil)
        XCTAssertEqual(nav.current, .tasks(.inbox), "a nil List selection must not blank the detail pane")
    }

    func testGoBackAndForwardAreSafeWhenEmpty() {
        let nav = NavigationCoordinator(current: .today)
        nav.goBack()
        nav.goForward()
        XCTAssertEqual(nav.current, .today)
    }

    func testReplaceCurrentDoesNotRecordHistory() {
        let nav = NavigationCoordinator(current: .today)
        nav.replaceCurrent(.live)
        XCTAssertEqual(nav.current, .live)
        XCTAssertFalse(nav.canGoBack)
    }
}
