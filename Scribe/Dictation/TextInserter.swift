import AppKit
import ApplicationServices
import CoreGraphics

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

    static func insert(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        guard hasAccessibilityPermission else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedToClipboard
        }

        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        postCommandV()

        // Give the target app time to read the pasteboard before restoring the
        // user's clipboard. Skip the restore if something else (the user, a
        // clipboard manager) has written to it in the meantime.
        try? await Task.sleep(for: .milliseconds(400))
        if pasteboard.changeCount == changeCount {
            restore(saved, to: pasteboard)
        }
        return .inserted
    }

    // MARK: - Private

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
