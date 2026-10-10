import SwiftUI
import TipKit

// TipKit tips shown with `.popoverTip` next to the feature they teach. All
// TipKit calls live in this file so an SDK change is a one-file fix.

/// ⌘K universal search / command bar (toolbar search button).
struct ScribeQuickSearchTip: Tip {
    var title: Text { Text("Search Everything") }
    var message: Text? {
        Text("Press ⌘K to jump to any note, task or meeting, or to run a command.")
    }
    var image: Image? { Image(systemName: "magnifyingglass") }
}

/// The toolbar Record button.
struct ScribeRecordTip: Tip {
    var title: Text { Text("Record a Conversation") }
    var message: Text? {
        Text("Click Record, or press ⇧⌘R from any app. Scribe transcribes on your Mac as you talk.")
    }
    var image: Image? { Image(systemName: "record.circle") }
}

/// The global dictation hotkey (recording status pill).
struct ScribeDictationTip: Tip {
    var title: Text { Text("Dictate Into Any App") }
    var message: Text? {
        Text("Set a dictation shortcut in Settings → Dictation, then speak and Scribe types where your cursor is.")
    }
    var image: Image? { Image(systemName: "mic.badge.plus") }
}

/// Natural-language task quick add.
struct ScribeTaskQuickAddTip: Tip {
    var title: Text { Text("Type Tasks Naturally") }
    var message: Text? {
        Text("Write “Call Sam tomorrow 3pm #work +Launch !high” — dates, tags, projects and priority are picked out for you.")
    }
    var image: Image? { Image(systemName: "text.badge.plus") }
}

enum ScribeTips {
    @MainActor static let quickSearch = ScribeQuickSearchTip()
    @MainActor static let record = ScribeRecordTip()
    @MainActor static let dictation = ScribeDictationTip()
    @MainActor static let taskQuickAdd = ScribeTaskQuickAddTip()

    /// Called once at launch. At most one tip a day, so they never pile up.
    /// UI tests and screenshot runs hide all tips so popovers can't cover
    /// the views under test.
    @MainActor
    static func configure() {
        if AppLaunchEnvironment.isUITesting || AppLaunchEnvironment.usesUITestFixtures {
            Tips.hideAllTipsForTesting()
        }
        do {
            try Tips.configure([.displayFrequency(.daily)])
        } catch {
            Log.ui.error("TipKit configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user found the feature on their own: retire its tip.
    @MainActor static func quickSearchUsed() { quickSearch.invalidate(reason: .actionPerformed) }
    @MainActor static func recordUsed() { record.invalidate(reason: .actionPerformed) }
    @MainActor static func taskQuickAddUsed() { taskQuickAdd.invalidate(reason: .actionPerformed) }
    @MainActor static func dictationUsed() { dictation.invalidate(reason: .actionPerformed) }
}
