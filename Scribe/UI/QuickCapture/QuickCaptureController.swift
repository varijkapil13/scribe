import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - Shortcut name

extension KeyboardShortcuts.Name {
    /// Global shortcut that toggles the Quick Capture panel.
    static let quickCapture = Self(
        "quickCapture",
        default: .init(.space, modifiers: [.control, .option])
    )
}

// MARK: - Panel

/// Borderless floating panel that can take keyboard focus without
/// activating Scribe, so capturing never pulls the user out of the app
/// they're in.
@MainActor
final class QuickCapturePanel: NSPanel {
    /// Esc while AppKit (not SwiftUI) handles the key.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Controller

/// Owns the Quick Capture panel: global shortcut, show / hide, positioning,
/// and what happens after a save (toast, or open in the main window).
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {

    static let shared = QuickCaptureController()

    private let model: QuickCaptureModel
    private var panel: QuickCapturePanel?
    private let toast: QuickCaptureToast
    private var shortcutRegistered = false
    /// Top edge to keep while the panel grows / shrinks with its content.
    private var anchoredTop: CGFloat?

    private override init() {
        model = QuickCaptureModel(
            defaults: UserDefaults.standard,
            isDictationAvailable: !AppLaunchEnvironment.isUITesting
        )
        toast = QuickCaptureToast()
        super.init()
        model.onSaved = { [weak self] outcome, openAfter in
            self?.didSave(outcome, openAfter: openAfter)
        }
        model.onCancel = { [weak self] in
            self?.hide()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// `openWindow` captured from a view that lives in a real scene (the
    /// menu-bar label), preferred over the one from the panel's hosted view
    /// when reopening a closed main window.
    var sceneOpenWindow: OpenWindowAction?

    /// Registers the global shortcut (default ⌃⌥Space). Idempotent.
    func registerShortcut() {
        guard !shortcutRegistered else { return }
        shortcutRegistered = true
        KeyboardShortcuts.onKeyUp(for: .quickCapture) {
            Task { @MainActor in QuickCaptureController.shared.toggle() }
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.prepareForShow()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        model.dictation.cancel()
        anchoredTop = nil
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// Focus loss closes the panel, except while dictation is starting
    /// (the microphone / speech permission prompt takes focus) or a save is
    /// in flight.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        if model.dictation.phase == .preparing || model.isSaving { return }
        hide()
    }

    /// Keeps the top edge fixed as the content grows (chips, extra lines),
    /// so the field doesn't jump under the cursor.
    func windowDidResize(_ notification: Notification) {
        guard let panel, let top = anchoredTop else { return }
        if abs(panel.frame.maxY - top) > 0.5 {
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
    }

    // MARK: - Private

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickCaptureView.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityIdentifier("quickCapturePanel")
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        let hosting = NSHostingController(
            rootView: QuickCaptureView(model: model, dictation: model.dictation)
        )
        // The window follows the SwiftUI content's size (chips, more lines).
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }

    /// Centred on the screen with the mouse (the one the user is working
    /// on), a third of the way down.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        if let fitting = panel.contentViewController?.view.fittingSize, fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }
        let origin = QuickCapturePanelGeometry.origin(panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        panel.setFrameOrigin(origin)
        anchoredTop = panel.frame.maxY
    }

    private func didSave(_ outcome: QuickCaptureSaveOutcome, openAfter: Bool) {
        let frame = panel?.frame
        hide()
        if openAfter {
            openInMainWindow(outcome.selection)
        } else {
            toast.show(message: outcome.message, near: frame)
        }
    }

    /// Brings up the main window and navigates to the saved item.
    private func openInMainWindow(_ selection: MainSelection) {
        NSApp.activate(ignoringOtherApps: true)
        let existing = NSApp.windows.first { $0.identifier?.rawValue == "main" }
        let wasVisible = existing?.isVisible ?? false
        if let action = sceneOpenWindow ?? model.openWindowAction {
            action(id: "main")
        } else {
            existing?.makeKeyAndOrderFront(nil)
        }
        if wasVisible {
            NotificationCenter.default.post(name: .scribeNavigate, object: selection)
            return
        }
        // A freshly opened window subscribes to navigation once it's on
        // screen; give it a moment before routing.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            NotificationCenter.default.post(name: .scribeNavigate, object: selection)
        }
    }
}

// MARK: - Toast

/// Brief confirmation shown after a save. Non-activating and click-through,
/// so it never takes focus from the app the user went back to.
@MainActor
final class QuickCaptureToast {

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Shows `message` centred where the capture panel was (`anchor`), or
    /// on the screen with the mouse.
    func show(message: String, near anchor: NSRect?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: QuickCaptureToastView(message: message))
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let anchor {
            panel.setFrameOrigin(NSPoint(x: (anchor.midX - size.width / 2).rounded(), y: (anchor.maxY - size.height).rounded()))
        } else if let visible = screen?.visibleFrame {
            let origin = QuickCapturePanelGeometry.origin(panelSize: size, visibleFrame: visible)
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        AccessibilityNotification.Announcement(message).post()

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}
