import Foundation

/// An app that, when it holds the microphone open, means "you're probably in a
/// meeting". Identified by the bundle ID CoreAudio reports for the process
/// doing the capture.
struct MeetingApp: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// A dedicated conferencing/calling app (Zoom, Teams, Slack huddles…).
        case conferencing
        /// A web browser — mic use there is usually Google Meet / a web call,
        /// but could be anything, so it's a weaker signal.
        case browser
        /// Any other app, only reported when "detect any app" is on.
        case other
    }

    /// Canonical bundle ID from the catalog (not the helper process's ID).
    let bundleID: String
    let name: String
    let kind: Kind
}

/// Pure lookup from a capturing process's bundle ID to a ``MeetingApp``.
///
/// CoreAudio frequently reports a *helper* process as the one doing input
/// (Chrome's audio service runs in `com.google.Chrome.helper`, new Teams in a
/// `com.microsoft.teams2.*` helper), so matching is by exact ID or dotted
/// prefix. Kept free of CoreAudio/AppKit so CI can pin it down.
enum MeetingAppCatalog {

    static let conferencing: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "Cisco-Systems.Spark": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord",
        "com.skype.skype": "Skype",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "ru.keepcoder.Telegram": "Telegram",
        "org.whispersystems.signal-desktop": "Signal",
        "com.amazon.Amazon-Chime": "Amazon Chime",
        "com.logmein.GoToMeeting": "GoTo Meeting",
        "com.ringcentral.glip": "RingCentral",
        "app.tuple.app": "Tuple",
        "co.around.Around": "Around",
        "com.pop.pop.app": "Pop",
    ]

    static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome",
        "com.apple.Safari": "Safari",
        // Safari (and every WKWebView) captures through the shared WebKit GPU
        // process, so this is the ID CoreAudio actually reports for Safari.
        "com.apple.WebKit.GPU": "Safari",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    /// System processes that open the mic for their own purposes (dictation,
    /// Siri, voice control). Never treated as a meeting, even with
    /// `includeOtherApps` on.
    static let ignored: Set<String> = [
        "com.apple.SpeechRecognitionCore",
        "com.apple.corespeechd",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.VoiceOver",
        "com.apple.speech.speechsynthesisd",
        "com.apple.DictationIM",
    ]

    /// Resolves a capturing process to a meeting app, or `nil` when it isn't
    /// one we should react to.
    ///
    /// - Parameters:
    ///   - bundleID: The bundle ID CoreAudio reports for the process.
    ///   - includeBrowsers: Whether browser mic use counts (Google Meet etc.).
    ///   - includeOtherApps: Whether *any* non-ignored app counts.
    ///   - fallbackName: Display name for an `.other` match (e.g. the running
    ///     app's localized name); defaults to the bundle ID.
    ///   - rules: The user's per-app overrides (see ``MeetingAppRules``):
    ///     disabled apps never match; "always count" apps match as `.other`
    ///     even with `includeOtherApps` off.
    static func match(
        bundleID: String,
        includeBrowsers: Bool = true,
        includeOtherApps: Bool = false,
        fallbackName: String? = nil,
        rules: MeetingAppRules = MeetingAppRules()
    ) -> MeetingApp? {
        guard !bundleID.isEmpty, !isIgnored(bundleID) else { return nil }
        if let (id, name) = lookup(bundleID, in: conferencing) {
            guard !rules.isDisabled(id) else { return nil }
            return MeetingApp(bundleID: id, name: name, kind: .conferencing)
        }
        if let (id, name) = lookup(bundleID, in: browsers) {
            guard includeBrowsers, !rules.isDisabled(id) else { return nil }
            return MeetingApp(bundleID: id, name: name, kind: .browser)
        }
        guard rules.countsOtherApp(bundleID, includeOtherApps: includeOtherApps) else { return nil }
        return MeetingApp(bundleID: bundleID, name: fallbackName ?? bundleID, kind: .other)
    }

    private static func isIgnored(_ bundleID: String) -> Bool {
        ignored.contains(bundleID) || ignored.contains { bundleID.hasPrefix($0 + ".") }
    }

    /// Exact match, else the longest catalog ID that is a dotted prefix of
    /// `bundleID` (so `com.microsoft.teams2.helper` → `com.microsoft.teams2`,
    /// not `com.microsoft.teams`).
    private static func lookup(_ bundleID: String, in table: [String: String]) -> (String, String)? {
        if let name = table[bundleID] { return (bundleID, name) }
        let best = table.keys
            .filter { bundleID.hasPrefix($0 + ".") }
            .max(by: { $0.count < $1.count })
        return best.map { ($0, table[$0]!) }
    }
}
