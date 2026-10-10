// Scribe/Shared/ScribeAppGroup.swift
//
// Shared between the app and its extensions (widgets, Share, Quick Look):
// this folder is compiled into the Scribe target (it lives under Scribe/, so
// SwiftPM builds it too) AND listed file-by-file in the extension targets in
// project.yml. Keep everything here Foundation-only and self-contained: no
// references to app types (TodoTask, NoteStore, …), no AppKit / SwiftUI.

import Foundation

/// The App Group container the app and its extensions exchange data through.
///
/// Layout inside the container:
///
///     widget-snapshot.json          app → widgets (ScribeSharedSnapshot)
///     WidgetRequests/<uuid>.json    widgets → app (ScribeWidgetTaskRequest)
///     ShareInbox/<id>/payload.json  Share extension → app (ScribeSharePayload)
///     ShareInbox/<id>/image-1.png   …plus the shared images
enum ScribeAppGroup {

    /// Must match `com.apple.security.application-groups` in every
    /// entitlements file (app + each extension).
    static let identifier = "group.com.varij.scribe"

    static let snapshotFileName = "widget-snapshot.json"
    static let widgetRequestsFolderName = "WidgetRequests"
    static let shareInboxFolderName = "ShareInbox"

    /// Darwin notification a widget posts after queueing a task request, so a
    /// running app applies it right away (it also drains on activation).
    static let widgetRequestNotificationName = "com.varij.scribe.widget-request"

    /// WidgetKit kinds (also used by the app to reload specific timelines).
    static let todayWidgetKind = "com.varij.scribe.widget.today"
    static let nextMeetingWidgetKind = "com.varij.scribe.widget.next-meeting"
    static let recordControlKind = "com.varij.scribe.control.record"

    /// The shared container, or nil when this process isn't entitled to the
    /// group (e.g. an unsigned development build).
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    // MARK: - Deep links (mirror ScribeDeepLink's grammar; covered by tests)

    /// `scribe://today`
    static var todayURL: URL { fixedURL("scribe://today") }

    /// `scribe://record/start`
    static var recordStartURL: URL { fixedURL("scribe://record/start") }

    /// `scribe://import-share` — tells the app to process the Share inbox.
    static var importShareURL: URL { fixedURL("scribe://import-share") }

    /// `scribe://note/<id>` (id percent-encoded).
    static func noteURL(id: String) -> URL {
        fixedURL("scribe://note/" + percentEncode(id))
    }

    /// `scribe://task/<id>` (id percent-encoded).
    static func taskURL(id: String) -> URL {
        fixedURL("scribe://task/" + percentEncode(id))
    }

    private static func fixedURL(_ string: String) -> URL {
        // The literals above are valid URLs; the fallback only guards against
        // a malformed id slipping past percent-encoding.
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    private static func percentEncode(_ raw: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    // MARK: - Darwin notification

    /// Posts `widgetRequestNotificationName` on the Darwin notify center
    /// (cross-process, no payload).
    static func postWidgetRequestNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(widgetRequestNotificationName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    // MARK: - JSON coding

    /// One encoder configuration for every shared file, so both sides agree.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
