// ScribeTests/UbiquitousVaultChangePlannerTests.swift
import XCTest
@testable import Scribe

/// The pure half of the iCloud vault observer (D-Sync-2).
final class UbiquitousVaultChangePlannerTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/vault/Documents/Scribe/Notes", isDirectory: true)

    private func path(_ relative: String) -> String { root.path + "/" + relative }

    func testCurrentItemsBecomeEvents() {
        let plan = UbiquitousVaultChangePlanner.plan(
            changed: [UbiquitousVaultItem(path: path("Ideas.md"), isCurrent: true)],
            removedPaths: [], root: root, alreadyRequested: []
        )
        XCTAssertEqual(plan.events, [NoteVaultEvent(path: path("Ideas.md"))])
        XCTAssertTrue(plan.downloads.isEmpty)
    }

    func testNonLocalItemsAreDownloadedOnceAndProduceNoEventYet() {
        let cloudOnly = UbiquitousVaultItem(path: path("Remote.md"), isCurrent: false)
        let first = UbiquitousVaultChangePlanner.plan(changed: [cloudOnly, cloudOnly], removedPaths: [],
                                                      root: root, alreadyRequested: [])
        XCTAssertEqual(first.downloads, [path("Remote.md")])
        XCTAssertTrue(first.events.isEmpty)

        let again = UbiquitousVaultChangePlanner.plan(changed: [cloudOnly], removedPaths: [],
                                                      root: root, alreadyRequested: [path("Remote.md")])
        XCTAssertTrue(again.downloads.isEmpty)

        let inFlight = UbiquitousVaultItem(path: path("Busy.md"), isCurrent: false, isDownloading: true)
        XCTAssertTrue(UbiquitousVaultChangePlanner.plan(changed: [inFlight], removedPaths: [],
                                                        root: root, alreadyRequested: []).downloads.isEmpty)
    }

    func testCompletedDownloadsAreReported() {
        let landed = UbiquitousVaultItem(path: path("Remote.md"), isCurrent: true)
        let plan = UbiquitousVaultChangePlanner.plan(changed: [landed], removedPaths: [],
                                                     root: root, alreadyRequested: [path("Remote.md")])
        XCTAssertEqual(plan.completed, [path("Remote.md")])
        XCTAssertEqual(plan.events.count, 1)
    }

    func testRemovalsBecomeEvents() {
        let plan = UbiquitousVaultChangePlanner.plan(changed: [], removedPaths: [path("Gone.md")],
                                                     root: root, alreadyRequested: [])
        XCTAssertEqual(plan.events, [NoteVaultEvent(path: path("Gone.md"))])
    }

    func testItemsOutsideTheVaultOrHiddenAreIgnored() {
        let items = [
            UbiquitousVaultItem(path: "/vault/Documents/Other/x.md", isCurrent: true),
            UbiquitousVaultItem(path: path(".obsidian/workspace.json"), isCurrent: false),
            UbiquitousVaultItem(path: path(".Note.md.icloud"), isCurrent: false),
            UbiquitousVaultItem(path: root.path, isCurrent: true),
        ]
        let plan = UbiquitousVaultChangePlanner.plan(changed: items, removedPaths: ["/elsewhere/a.md"],
                                                     root: root, alreadyRequested: [])
        XCTAssertTrue(plan.events.isEmpty)
        XCTAssertTrue(plan.downloads.isEmpty)
    }

    func testInitialDownloadsCoverAttachmentsToo() {
        let items = [
            UbiquitousVaultItem(path: path("A.md"), isCurrent: true),
            UbiquitousVaultItem(path: path("attachments/n1/photo.jpg"), isCurrent: false),
        ]
        XCTAssertEqual(UbiquitousVaultChangePlanner.initialDownloads(items: items, root: root),
                       [path("attachments/n1/photo.jpg")])
    }

    func testEventsFeedTheWriteGuardFilter() {
        // An attachment event alone never needs a reconcile; a note does.
        let attachment = [NoteVaultEvent(path: path("attachments/n1/photo.jpg"))]
        XCTAssertFalse(VaultWriteGuard.requiresReconcile(events: attachment, root: root, isOwnWrite: { _ in false }))
        let note = [NoteVaultEvent(path: path("Ideas.md"))]
        XCTAssertTrue(VaultWriteGuard.requiresReconcile(events: note, root: root, isOwnWrite: { _ in false }))
        XCTAssertFalse(VaultWriteGuard.requiresReconcile(events: note, root: root, isOwnWrite: { _ in true }))
    }
}
