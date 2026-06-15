import Foundation

// MARK: - Notification names
//
// These live in their own file (in the SwiftPM target) rather than in
// MainWindowView.swift, because the editor rewrite excludes the SwiftUI view
// layer (MainWindowView et al.) from the `swift test` SwiftPM target. View
// *models* that stay in the target — e.g. TranscriptDetailViewModel — still
// post/observe these names, so the definitions must remain compiled there.

extension Notification.Name {
    static let openScribeSettings = Notification.Name("scribe.openSettings")
    static let scribeSessionUpdated = Notification.Name("scribe.sessionUpdated")
    static let scribeRequestNavigateToNote = Notification.Name("scribe.requestNavigateToNote")
    // Menu-bar command tree → main window. The menu items are the canonical,
    // VoiceOver-announced home of these shortcuts; MainWindowView observes them.
    static let scribeToggleCommandBar = Notification.Name("scribe.toggleCommandBar")
    static let scribeGoBack = Notification.Name("scribe.goBack")
    static let scribeGoForward = Notification.Name("scribe.goForward")
    static let scribeToggleSidebar = Notification.Name("scribe.toggleSidebar")
    static let scribeNewNote = Notification.Name("scribe.newNote")
    static let scribeNewDailyNote = Notification.Name("scribe.newDailyNote")
    static let scribeNavigate = Notification.Name("scribe.navigate")  // userInfo["selection"]
    static let scribeScrollToOffset = Notification.Name("scribe.scrollToOffset")  // userInfo["offset"]
}
