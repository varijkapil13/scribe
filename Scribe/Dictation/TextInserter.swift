import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Pure policy for the dictation paste-and-restore dance, kept free of AppKit
/// state so it is unit-testable.
enum DictationPastePolicy {

    /// Pasteboard types that mark the temporary dictation item so clipboard
    /// managers / sync tools skip it (see nspasteboard.org): Transient = "will
    /// be restored shortly, don't record"; Concealed = "don't display or
    /// persist the contents".
    static let temporaryItemMarkerTypes: [String] = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
    ]

    /// How long to wait after posting ⌘V before putting the user's clipboard
    /// back. The target app reads the pasteboard asynchronously when it
    /// handles the key event; a busy app (or a large paste) can take well
    /// over the old fixed 400 ms, and restoring too early pastes the user's
    /// OLD clipboard instead of the dictation. Grows with the text length,
    /// capped so the user's clipboard isn't held hostage for long.
    static func restoreDelayMilliseconds(forTextLength length: Int) -> Int {
        let base = 750
        let perThousandChars = 100
        let extra = (max(0, length) / 1_000) * perThousandChars
        return min(base + extra, maxRestoreDelayMilliseconds)
    }

    static let maxRestoreDelayMilliseconds = 2_000

    /// Restore only when nobody else (the user, a clipboard manager) wrote to
    /// the pasteboard after we placed the dictation on it.
    static func shouldRestore(currentChangeCount: Int, changeCountAfterWrite: Int) -> Bool {
        currentChangeCount == changeCountAfterWrite
    }
}

/// Types dictated text into whatever app has keyboard focus.
///
/// Uses the same approach as other Mac dictation tools: put the text on the
/// pasteboard, synthesize ⌘V, then put the user's previous clipboard back.
/// Posting key events needs the Accessibility permission. Without it the text
/// is left on the clipboard so nothing is lost and the user can paste it.
@MainActor
enum TextInserter {

    enum Outcome: Equatable {
        /// Pasted into the focused app.
        case inserted
        /// No Accessibility permission: the text is on the clipboard.
        case copiedToClipboard
        /// Secure Event Input is on (a password field, or an app such as a
        /// terminal / password manager holding it). Synthesized keystrokes are
        /// not delivered, so the text was left on the clipboard instead.
        case secureInputActive
    }

    /// Whether Scribe may post synthetic key events.
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Scribe to control your computer" prompt and
    /// adds Scribe to the Accessibility list. Returns the current state.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        // The value of kAXTrustedCheckOptionPrompt, spelled out because the
        // imported global is a mutable C var that Swift 6 rejects.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        Permissions.openSystemPreferences(for: "Privacy_Accessibility")
    }

    /// Whether some process has Secure Event Input enabled. While it is on,
    /// posted key events don't reach the focused field.
    static var isSecureInputActive: Bool {
        // Carbon (HIToolbox) API; still the only public way to query this.
        IsSecureEventInputEnabled()
    }

    static func insert(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        guard hasAccessibilityPermission else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedToClipboard
        }
        guard !isSecureInputActive else {
            // Don't claim "Inserted" for a paste that can't land; leave the
            // text on the clipboard (not marked transient — the user needs it).
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .secureInputActive
        }

        let saved = snapshot(of: pasteboard)
        writeTemporary(text, to: pasteboard)
        let changeCount = pasteboard.changeCount

        postCommandV()

        // Give the target app time to consume the paste before restoring the
        // user's clipboard. Skip the restore if something else (the user, a
        // clipboard manager) has written to it in the meantime.
        let delay = DictationPastePolicy.restoreDelayMilliseconds(forTextLength: text.utf16.count)
        try? await Task.sleep(for: .milliseconds(delay))
        if DictationPastePolicy.shouldRestore(
            currentChangeCount: pasteboard.changeCount,
            changeCountAfterWrite: changeCount
        ) {
            restore(saved, to: pasteboard)
        }
        return .inserted
    }

    // MARK: - Private

    /// Puts the dictation on the pasteboard as a single item flagged
    /// Transient + Concealed so clipboard managers don't record it.
    private static func writeTemporary(_ text: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in DictationPastePolicy.temporaryItemMarkerTypes {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { result, type in
                if let data = item.data(forType: type) { result[type] = data }
            }
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
