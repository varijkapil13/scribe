import AppIntents
import Foundation

/// "Scribe Focus" — a Focus filter (System Settings → Focus → <a Focus> →
/// Focus Filters → Scribe). While the Focus is on, Scribe can stay quiet about
/// detected meetings and keep reminders off screen. The system runs
/// `perform()` with the configured values when the Focus turns on and with the
/// defaults (everything off) when it turns off; the values live in
/// `UserDefaults` via `ScribeFocusPreferences`, which the notification code
/// reads.
struct ScribeFocusFilter: SetFocusFilterIntent {

    static var title: LocalizedStringResource { "Scribe Focus" }

    @Parameter(title: "Mute meeting detection prompts", default: false)
    var muteMeetingPrompts: Bool

    @Parameter(title: "Hide reminder notifications", default: false)
    var hideReminders: Bool

    init() {}

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if muteMeetingPrompts { parts.append("Meeting prompts muted") }
        if hideReminders { parts.append("Reminders hidden") }
        let subtitle = parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
        return DisplayRepresentation(title: "Scribe Focus", subtitle: "\(subtitle)")
    }

    func perform() async throws -> some IntentResult {
        ScribeFocusPreferences.apply(muteMeetingPrompts: muteMeetingPrompts, hideReminders: hideReminders)
        return .result()
    }
}
