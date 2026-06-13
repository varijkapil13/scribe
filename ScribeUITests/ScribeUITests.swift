import XCTest

/// XCUITest foundation for Scribe.
///
/// Every test launches the app with `--uitesting`, which gates the audio /
/// ScreenCaptureKit capture stack and the launch-time permission prompts (see
/// `AppLaunchEnvironment`) so the app boots clean under the test runner.
///
/// Assertions prefer the app's existing accessibility labels and visible text
/// over bespoke identifiers — Scribe already ships rich `.accessibilityLabel`
/// coverage, so these tests piggyback on it and stay decoupled from layout.
final class ScribeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches the app under test with the audio gate engaged.
    @discardableResult
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        return app
    }

    /// The app's main window. Scribe titles its primary `Window` scene
    /// "Scribe"; fall back to the first window if the title lookup misses on a
    /// future macOS that decorates it.
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        let titled = app.windows["Scribe"]
        return titled.exists ? titled : app.windows.firstMatch
    }

    /// Opens the ⌘K command palette and waits for its search field. The field
    /// carries `.accessibilityLabel("Command bar")`.
    private func openCommandPalette(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey("k", modifierFlags: .command)
        let field = app.searchFields["Command bar"]
        if field.waitForExistence(timeout: 5) { return field }
        // Some macOS builds surface a plain text field for the palette input.
        let textField = app.textFields["Command bar"]
        XCTAssertTrue(textField.waitForExistence(timeout: 5),
                      "Command palette did not appear after ⌘K")
        return textField
    }

    // MARK: - (a) Launch

    func testAppLaunchesToAWindow() {
        let app = launchApp()
        XCTAssertEqual(app.state, .runningForeground, "App is not running in the foreground")
        XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 10),
                      "Main window never appeared")
    }

    // MARK: - (b) ⌘K → New Note → editor

    func testCommandPaletteNewNoteOpensEditor() {
        let app = launchApp()
        XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 10))

        _ = openCommandPalette(app)

        // The palette lists a static "New Note" action (CommandRegistry); its
        // row exposes `.accessibilityLabel(item.title)` == "New Note".
        let newNote = app.buttons["New Note"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 5),
                      "\"New Note\" command not found in the palette")
        newNote.click()

        // NoteDetailView is the only surface with an "Enter focus mode"
        // control — a stable signal that a note editor opened.
        let focusToggle = app.buttons["Enter focus mode"]
        XCTAssertTrue(focusToggle.waitForExistence(timeout: 5),
                      "Note editor did not open after running \"New Note\"")
    }

    // MARK: - (b2) Note editor exposes inline tags (Slice C1)

    /// Notes used to store tags with no editor UI. The note header now hosts the
    /// same `TagTokenField` as the Tasks inspector; its entry field carries
    /// `.accessibilityLabel("Add tag")`.
    func testNoteEditorShowsInlineTagField() {
        let app = launchApp()
        XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 10))

        _ = openCommandPalette(app)
        let newNote = app.buttons["New Note"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 5),
                      "\"New Note\" command not found in the palette")
        newNote.click()

        let tagField = app.textFields["Add tag"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5),
                      "Note editor did not show the inline tag field")
    }

    // MARK: - (c) ⌘1 / ⌘2 / ⌘3 surface switching

    func testSurfaceSwitchingShortcuts() {
        let app = launchApp()
        let window = mainWindow(app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // ⌘1 → Capture / Today. TodayView labels its tasks rail "Today's tasks".
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["Today's tasks"].waitForExistence(timeout: 5),
                      "⌘1 did not show the Today surface")

        // ⌘3 → Tasks. The Inbox list shows a "Quick-add syntax help" control.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Quick-add syntax help"].waitForExistence(timeout: 5),
                      "⌘3 did not show the Tasks surface")

        // ⌘2 → Notes. The All-notes browser's empty detail reads "No Note Selected".
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No Note Selected"].waitForExistence(timeout: 5),
                      "⌘2 did not show the Notes surface")
    }

    // MARK: - (d) Transcript Export reachable (regression guard)

    /// Guards the bug where the transcript Export control lived in a `.toolbar`
    /// that got dropped in the `.session(id)` detail route. It now lives in an
    /// in-body action bar in `TranscriptDetailView`, so it must be reachable
    /// whenever a transcript is open.
    ///
    /// A freshly-launched test store has no recordings; in that case the test
    /// skips rather than seeding the production database. When a recording is
    /// present the Export button must be hittable.
    func testTranscriptExportControlIsReachable() throws {
        let app = launchApp()
        XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 10))

        // Navigate to the Recordings archive via the command palette.
        let field = openCommandPalette(app)
        field.typeText("Recordings")
        let recordingsAction = app.buttons["Recordings"]
        XCTAssertTrue(recordingsAction.waitForExistence(timeout: 5),
                      "\"Recordings\" command not found in the palette")
        recordingsAction.click()

        // Open the first recording row, if any. Each row exposes the session
        // title (or "Untitled recording") as its accessibility label.
        let firstRecording = app.buttons["Untitled recording"].firstMatch
        let anyRow = firstRecording.exists ? firstRecording : app.outlineRows.firstMatch
        guard anyRow.waitForExistence(timeout: 3) else {
            throw XCTSkip("No recordings in the test store — nothing to open. " +
                          "Export reachability is exercised when a transcript exists.")
        }
        anyRow.click()

        // The Export control is a Button { Label("Export", …) } in the
        // in-body action bar — reachable in the detail-pane route.
        let exportButton = app.buttons["Export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5),
                      "Export control not reachable in the open transcript")
    }
}
