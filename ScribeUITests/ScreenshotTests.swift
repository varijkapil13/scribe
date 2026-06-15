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
///      stable, ordered filename (`01-today.png`, `02-tasks-inbox.png`, …). CI
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

        // 1. Today / Capture surface (⌘1).
        goToSurface(key: "1")
        _ = app.descendants(matching: .any)["Today's tasks"].waitForExistence(timeout: 10)
        capture("01-today")

        // 2. Tasks → Inbox (⌘3 switches to the Tasks surface; default is Inbox).
        goToSurface(key: "3")
        _ = app.buttons["Quick-add syntax help"].waitForExistence(timeout: 10)
        clickSidebar("Inbox")
        capture("02-tasks-inbox")

        // 3. Tasks → Upcoming.
        clickSidebar("Upcoming")
        capture("03-tasks-upcoming")

        // 4. Tasks → Calendar.
        clickSidebar("Calendar")
        capture("04-tasks-calendar")

        // 5. Tasks → a project (seeded "Website Relaunch").
        clickSidebar("Website Relaunch")
        capture("05-tasks-project")

        // 6. Notes browser (⌘2).
        goToSurface(key: "2")
        clickSidebar("All Notes")
        capture("06-notes-browser")

        // 7. Notes → open the rich note in the editor.
        openNote(titled: "Architecture Overview")
        capture("07-note-editor")

        // 8. Recordings / Transcript (back to Capture surface, then the archive).
        goToSurface(key: "1")
        clickSidebar("Recordings")
        capture("08-recordings")
        openFirstRecording()
        capture("09-transcript")

        // 9. Settings (⌘,). Opens the separate Settings window.
        openSettings()
        capture("10-settings")
    }

    // MARK: - Navigation helpers (all best-effort)

    private var mainWindow: XCUIElement {
        let titled = app.windows["Scribe"]
        return titled.exists ? titled : app.windows.firstMatch
    }

    /// Switches the primary surface via its ⌘ shortcut and waits briefly.
    private func goToSurface(key: String) {
        app.typeKey(key, modifierFlags: .command)
        usleep(800_000)
    }

    /// Clicks a sidebar row identified by its visible label. No-op (logged) if
    /// the row never appears so the walk can continue to the next screen.
    private func clickSidebar(_ label: String) {
        let candidates: [XCUIElement] = [
            app.buttons[label],
            app.staticTexts[label],
            app.cells.containing(.staticText, identifier: label).element,
            app.outlineRows.containing(.staticText, identifier: label).element
        ]
        for element in candidates where element.waitForExistence(timeout: 6) {
            if element.isHittable {
                element.click()
                usleep(800_000)
                return
            }
        }
        NSLog("Screenshot harness: sidebar row \"\(label)\" not reachable — continuing.")
    }

    /// Opens a note from the All-Notes list by its title.
    private func openNote(titled title: String) {
        let candidates: [XCUIElement] = [
            app.buttons[title],
            app.staticTexts[title],
            app.cells.containing(.staticText, identifier: title).element
        ]
        for element in candidates where element.waitForExistence(timeout: 8) {
            if element.isHittable {
                element.click()
                usleep(1_000_000)
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
            usleep(1_000_000)
        } else {
            NSLog("Screenshot harness: no recording row reachable — continuing.")
        }
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
