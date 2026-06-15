import Foundation

/// Launch-time environment flags read from the process arguments.
///
/// The `--uitesting` flag lets XCUITest boot Scribe without its audio /
/// ScreenCaptureKit capture stack and without firing microphone / speech /
/// screen-recording permission prompts — the app's normal launch boots those
/// services and crashes a headless test host. The gate is read once at launch
/// and is a no-op (returns `false`) for every production run, so behavior is
/// byte-identical when the flag is absent.
enum AppLaunchEnvironment {

    /// `true` when the process was launched with `--uitesting` (set by
    /// `XCUIApplication.launchArguments` in the UI-test target).
    static let isUITesting: Bool =
        ProcessInfo.processInfo.arguments.contains("--uitesting")

    /// `true` when the process was launched with `--uitest-fixtures` (or with
    /// the environment variable `SCRIBE_UITEST=1`). In this mode the app
    /// redirects its SQLite database and notes vault to a fresh temporary
    /// directory and seeds them with a deterministic fixture dataset (a few
    /// projects, tasks across the Inbox / Today / Upcoming buckets, notes
    /// including one with Markdown + a Mermaid diagram, and a recorded
    /// transcript). This exists purely so the screenshot harness has a stable,
    /// reproducible dataset to photograph; it never runs on a production launch.
    ///
    /// IMPORTANT: every consumer of this flag must short-circuit to its
    /// production behavior when the flag is absent, so a normal launch is
    /// byte-identical to before this flag existed.
    static let usesUITestFixtures: Bool = {
        if ProcessInfo.processInfo.arguments.contains("--uitest-fixtures") { return true }
        if ProcessInfo.processInfo.environment["SCRIBE_UITEST"] == "1" { return true }
        return false
    }()

    /// The temporary root directory for fixture mode. All fixture state (the
    /// SQLite DB and the notes vault) lives under here, so a CI run leaves no
    /// trace in the user's real Application Support / Documents folders. Created
    /// lazily on first access and reused for the lifetime of the process.
    ///
    /// `nil` when fixtures are not active.
    static let fixtureRoot: URL? = {
        guard usesUITestFixtures else { return nil }
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScribeUITestFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Path to the fixture SQLite database. `nil` outside fixture mode — the
    /// production `DatabaseManager.shared` then uses its normal Application
    /// Support location and is completely unaffected.
    static var fixtureDatabasePath: String? {
        fixtureRoot.map { $0.appendingPathComponent("scribe.db").path }
    }

    /// Root of the fixture notes vault. `nil` outside fixture mode.
    static var fixtureNotesVaultRoot: URL? {
        fixtureRoot?.appendingPathComponent("Notes", isDirectory: true)
    }
}
