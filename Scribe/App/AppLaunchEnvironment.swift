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
}
