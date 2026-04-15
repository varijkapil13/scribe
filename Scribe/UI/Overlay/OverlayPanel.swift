import AppKit

// MARK: - OverlayPanel

/// A custom floating NSPanel that hosts the live transcript overlay.
///
/// The panel floats above all windows, joins all Spaces, and supports full-screen
/// auxiliary mode so it remains visible during presentations and screen shares.
final class OverlayPanel: NSPanel {

    // MARK: - Default Dimensions

    private static let defaultWidth: CGFloat = 400
    private static let defaultHeight: CGFloat = 500
    private static let minimumWidth: CGFloat = 250
    private static let minimumHeight: CGFloat = 200

    // MARK: - Initialization

    init() {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: Self.defaultWidth,
            height: Self.defaultHeight
        )

        super.init(
            contentRect: contentRect,
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .utilityWindow,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        configurePanel()
    }

    // MARK: - Configuration

    private func configurePanel() {
        // Float above regular windows.
        isFloatingPanel = true
        level = .floating

        // Appear on all Spaces and work alongside full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Allow dragging from any part of the panel background.
        isMovableByWindowBackground = true

        // Transparent title bar for a clean, modern appearance.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Slightly translucent background.
        backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        isOpaque = false

        hasShadow = true

        // Size constraints.
        minSize = NSSize(width: Self.minimumWidth, height: Self.minimumHeight)

        // Center the panel on the main screen.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let originX = screenFrame.maxX - Self.defaultWidth - 20
            let originY = screenFrame.maxY - Self.defaultHeight - 20
            setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        // Accessibility
        setAccessibilityRole(.window)
        setAccessibilityLabel("Live Transcript Overlay")
    }

    // MARK: - Key / Main Behavior

    /// Allow the panel to become key so text can be selected and copied.
    override var canBecomeKey: Bool { true }

    /// Prevent the panel from becoming the main window, keeping the
    /// host application's main window status intact.
    override var canBecomeMain: Bool { false }
}
