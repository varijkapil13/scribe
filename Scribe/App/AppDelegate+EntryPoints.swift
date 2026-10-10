import AppKit

/// External entry points owned by the app delegate: opened URLs / Markdown
/// files and the Dock menu. Everything routes through `ScribeEntryRouter`.
///
/// URLs are handled here and nowhere else — the app deliberately has no
/// SwiftUI `.onOpenURL`, so a `scribe://` link is never acted on twice.
extension AppDelegate {

    // MARK: - Opened URLs and documents

    /// `scribe://` links (CFBundleURLTypes) and Markdown files opened with
    /// Scribe (CFBundleDocumentTypes: Finder "Open With", Dock drops).
    @objc func application(_ application: NSApplication, open urls: [URL]) {
        ScribeEntryRouter.shared.handle(urls: urls)
    }

    // MARK: - Dock menu

    @objc func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(dockItem("New Note", action: #selector(dockNewNote(_:))))
        let recordingTitle = ScribeEntryRouter.shared.isRecording ? "Stop Recording" : "Start Recording"
        menu.addItem(dockItem(recordingTitle, action: #selector(dockToggleRecording(_:))))
        let dictationTitle = DictationController.shared.isActive ? "Stop Dictation" : "Start Dictation"
        menu.addItem(dockItem(dictationTitle, action: #selector(dockToggleDictation(_:))))
        return menu
    }

    private func dockItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dockNewNote(_ sender: Any?) {
        ScribeEntryRouter.shared.createNote(title: "", body: "")
    }

    @objc private func dockToggleRecording(_ sender: Any?) {
        let router = ScribeEntryRouter.shared
        if router.isRecording {
            router.stopRecording()
        } else {
            router.startRecording()
        }
    }

    @objc private func dockToggleDictation(_ sender: Any?) {
        ScribeEntryRouter.shared.toggleDictation()
    }

    // MARK: - Install

    /// Called from `applicationDidFinishLaunching`: wires the router (Services
    /// provider, queued launch URLs) to this delegate.
    func installEntryPoints() {
        ScribeEntryRouter.shared.install(delegate: self)
    }
}
