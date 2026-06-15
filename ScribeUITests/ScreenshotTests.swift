import XCTest

/// Automated screenshot harness.
///
/// Launches Scribe in fixture mode (`--uitest-fixtures`), walks every major
/// surface, and saves a PNG of each one. The seeded, deterministic dataset
/// (see `UITestFixtures`) means the captures are reproducible across runs.
///
/// Output:
///   1. Each PNG is written to the directory named by the `SCRIBE_SCREENSHOT_DIR`
///      environment variable (falling back to `NSTemporaryDirectory()`), with a
///      stable, ordered filename (`01-today.png`, `02-tasks-inbox.png`, …,
///      `11-bases.png` / `12-bases-board.png` / `13-bases-card.png`). CI
///      uploads that directory as the `ui-screenshots` artifact.
///   2. Each PNG is ALSO attached to the test result via `XCTAttachment` with
///      `.keepAlways` lifetime, so even if the directory upload misses it the
///      images survive inside the `.xcresult` bundle.
///
/// The harness is deliberately resilient: a screen that can't be reached is
/// logged and skipped (we still photograph whatever is on screen) so one bad
/// surface never fails the whole run. CI runs this job `continue-on-error`.
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    /// Resolved once: the directory PNGs are written to.
    private lazy var screenshotDirectory: URL = {
        // `xcodebuild test` forwards any `TEST_RUNNER_<NAME>` build setting into
        // the test runner process's environment as `<NAME>` (prefix stripped),
        // so the CI passes the directory that way. Fall back to a plain inherited
        // env var, then to the temp dir.
        let environment = ProcessInfo.processInfo.environment
        let env = environment["SCRIBE_SCREENSHOT_DIR"]
        let base: URL
        if let env, !env.isEmpty {
            base = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scribe-screenshots", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    override func setUp() {
        super.setUp()
        // Capture every screen even if an intermediate assertion is unhappy.
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitest-fixtures"]
        app.launchEnvironment["SCRIBE_UITEST"] = "1"
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - The walk

    func testCaptureAllScreens() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 30),
                      "Main window never appeared")
        // Give SwiftUI a beat to lay out the seeded data after first paint.
        sleep(2)

        // 1. Today / Capture surface (⌘1). Wait for the Today section header.
        goToSurface(key: "1", waitingFor: app.descendants(matching: .any)["Today's tasks"])
        capture("01-today")

        // 2. Tasks → Inbox (⌘3 switches to the Tasks surface; default is Inbox).
        goToSurface(key: "3", waitingFor: app.buttons["Quick-add syntax help"])
        // A seeded Inbox-only task confirms the Inbox detail has actually loaded.
        clickSidebar("Inbox", waitingFor: app.descendants(matching: .any)["Buy domain renewal"])
        capture("02-tasks-inbox")

        // 3. Tasks → Upcoming (seeded upcoming task is unique to this list).
        clickSidebar("Upcoming", waitingFor: app.descendants(matching: .any)["Recruit 5 participants"])
        capture("03-tasks-upcoming")

        // 4. Tasks → Calendar (no reliably-unique label — fixed settle).
        clickSidebar("Calendar")
        capture("04-tasks-calendar")

        // 5. Tasks → a project (seeded "Website Relaunch"); wait for one of its
        // tasks so the detail has switched away from Calendar before capture.
        clickSidebar("Website Relaunch", waitingFor: app.descendants(matching: .any)["Finalize launch checklist"])
        capture("05-tasks-project")

        // 6. Notes browser (⌘2).
        goToSurface(key: "2")
        clickSidebar("All Notes", waitingFor: app.descendants(matching: .any)["Architecture Overview"])
        capture("06-notes-browser")

        // 7. Notes → open the rich note in the editor.
        openNote(titled: "Architecture Overview")
        capture("07-note-editor")

        // 8. Notes → Bases (table / board / card).
        captureBases()

        // 9. Recordings / Transcript (back to Capture surface, then the archive).
        goToSurface(key: "1")
        clickSidebar("Recordings", waitingFor: app.descendants(matching: .any)["Weekly Sync — Product"])
        capture("08-recordings")
        openFirstRecording()
        capture("09-transcript")

        // 10. Settings (⌘,). Opens the separate Settings window.
        openSettings()
        capture("10-settings")
    }

    // MARK: - Navigation helpers (all best-effort)

    private var mainWindow: XCUIElement {
        let titled = app.windows["Scribe"]
        return titled.exists ? titled : app.windows.firstMatch
    }

    /// Settle interval used when there is no screen-specific element to wait
    /// for. The detail pane re-subscribes to GRDB asynchronously after a
    /// selection change, so a too-short wait can photograph the *previous*
    /// screen. ~1.8s comfortably covers the async repaint.
    private static let settleMicroseconds: UInt32 = 1_800_000

    /// Blocks until `element` exists (so the new screen has actually painted)
    /// or `timeout` elapses, then always pauses briefly to let the final layout
    /// pass land. Falls back to the full settle when no element is supplied.
    private func settle(forElement element: XCUIElement? = nil, timeout: TimeInterval = 6) {
        if let element {
            if element.waitForExistence(timeout: timeout) {
                // Element present — short beat for the surrounding layout/paint.
                usleep(400_000)
                return
            }
            NSLog("Screenshot harness: expected element never appeared — falling back to fixed settle.")
        }
        usleep(Self.settleMicroseconds)
    }

    /// Switches the primary surface via its ⌘ shortcut, then waits — for the
    /// given screen-specific element when supplied, otherwise the fixed settle.
    private func goToSurface(key: String, waitingFor element: XCUIElement? = nil) {
        app.typeKey(key, modifierFlags: .command)
        settle(forElement: element)
    }

    /// Clicks a sidebar row identified by its visible label, then waits for the
    /// target screen to actually reflect the new selection before returning so
    /// the next `capture(...)` photographs the right surface. Pass `waitingFor`
    /// an element unique to the destination screen for a precise wait; without
    /// it the fixed ~1.8s settle is used. No-op (logged) if the row never
    /// appears so the walk can continue to the next screen.
    private func clickSidebar(_ label: String, waitingFor element: XCUIElement? = nil) {
        let candidates: [XCUIElement] = [
            app.buttons[label],
            app.staticTexts[label],
            app.cells.containing(.staticText, identifier: label).element,
            app.outlineRows.containing(.staticText, identifier: label).element
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 6) {
            if candidate.isHittable {
                candidate.click()
                settle(forElement: element)
                return
            }
        }
        NSLog("Screenshot harness: sidebar row \"\(label)\" not reachable — continuing.")
    }

    /// Opens a note from the All-Notes list by its title, then waits for the
    /// editor to actually load that note (its title rendered in the detail
    /// pane) before returning so the capture isn't of the previous note.
    private func openNote(titled title: String) {
        let candidates: [XCUIElement] = [
            app.buttons[title],
            app.staticTexts[title],
            app.cells.containing(.staticText, identifier: title).element
        ]
        for element in candidates where element.waitForExistence(timeout: 8) {
            if element.isHittable {
                element.click()
                // The editor renders the title as a heading; wait for a second
                // occurrence (list row + editor heading) so we know the detail
                // pane has switched to this note.
                let editorTitle = app.staticTexts.matching(identifier: title)
                if !editorTitle.element(boundBy: 1).waitForExistence(timeout: 6) {
                    usleep(Self.settleMicroseconds)
                } else {
                    usleep(400_000)
                }
                return
            }
        }
        NSLog("Screenshot harness: note \"\(title)\" not reachable — continuing.")
    }

    /// Opens the first recording row in the Recordings archive, if any.
    private func openFirstRecording() {
        let titled = app.buttons["Weekly Sync — Product"].firstMatch
        let candidate = titled.exists ? titled : app.outlineRows.firstMatch
        if candidate.waitForExistence(timeout: 8), candidate.isHittable {
            candidate.click()
            settle()
        } else {
            NSLog("Screenshot harness: no recording row reachable — continuing.")
        }
    }

    /// Navigates to the Bases screen (Notes surface → "Bases" sidebar row) and,
    /// when reachable, walks its three layouts. The view-state identifiers come
    /// from the Bases views themselves (`bases-screen`, `bases-layout-*`,
    /// `bases-group-menu`). Best-effort throughout: each step is skipped (and
    /// logged) if its control isn't reachable, so the walk always continues.
    private func captureBases() {
        // Notes surface is already active from the previous step.
        clickSidebar("Bases", waitingFor: app.descendants(matching: .any)["bases-screen"])
        capture("11-bases")

        // Board layout — needs a group-by key to render columns rather than the
        // "Choose a property to group by" hint, so pick the seeded `status`
        // select property from the Group menu first.
        let groupMenu = app.descendants(matching: .any)["bases-group-menu"]
        if groupMenu.waitForExistence(timeout: 4), groupMenu.isHittable {
            groupMenu.click()
            usleep(400_000)
            let statusItem = app.menuItems["status"]
            if statusItem.waitForExistence(timeout: 4), statusItem.isHittable {
                statusItem.click()
                usleep(400_000)
            } else {
                // Dismiss the menu if the option wasn't found.
                app.typeKey(.escape, modifierFlags: [])
            }
        }
        if selectBasesLayout("board") {
            capture("12-bases-board")
        }

        // Card layout.
        if selectBasesLayout("card") {
            capture("13-bases-card")
        }
    }

    /// Selects a Bases layout segment (`table` / `board` / `card`) and settles.
    /// Returns false (logged) when the segment isn't reachable so the caller
    /// can skip that capture.
    @discardableResult
    private func selectBasesLayout(_ layout: String) -> Bool {
        let id = "bases-layout-\(layout)"
        let candidates: [XCUIElement] = [
            app.radioButtons[id],
            app.buttons[id],
            app.descendants(matching: .any)[id]
        ]
        for element in candidates where element.waitForExistence(timeout: 4) {
            if element.isHittable {
                element.click()
                usleep(700_000)
                return true
            }
        }
        NSLog("Screenshot harness: Bases layout \"\(layout)\" not reachable — continuing.")
        return false
    }

    /// Opens the Settings scene via ⌘, and waits for its window.
    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        usleep(1_500_000)
    }

    // MARK: - Capture

    /// Saves a PNG of the whole app (all windows) under `name.png` in the
    /// screenshot directory AND attaches it to the test result.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        // (1) Attachment — survives inside the .xcresult bundle.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // (2) PNG on disk — uploaded directly as the artifact.
        let url = screenshotDirectory.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            NSLog("Screenshot harness: wrote \(url.path)")
        } catch {
            NSLog("Screenshot harness: failed to write \(url.path): \(error)")
        }
    }
}
