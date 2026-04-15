import AppKit
import SwiftUI

// MARK: - OverlayManager

/// Manages the lifecycle of the floating transcript overlay panel, including creation,
/// visibility toggling, and updating its hosted SwiftUI content.
@MainActor
final class OverlayManager: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isVisible: Bool = false

    // MARK: - Panel

    private var panel: OverlayPanel?

    // MARK: - Show / Hide

    /// Displays the overlay panel with the provided SwiftUI view as its content.
    ///
    /// If the panel has not yet been created it is initialised lazily. Subsequent
    /// calls replace the hosted view content.
    ///
    /// - Parameter view: The SwiftUI view to host inside the panel.
    func showOverlay<Content: View>(with view: Content) {
        let overlayPanel = panel ?? createPanel()
        panel = overlayPanel

        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        overlayPanel.contentView = hostingView

        overlayPanel.orderFrontRegardless()
        isVisible = true
    }

    /// Hides the overlay panel without releasing it, preserving its position and size
    /// for the next time it is shown.
    func hideOverlay() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Toggles the overlay's visibility. When showing, the provided view is used as content.
    ///
    /// - Parameter view: The SwiftUI view to host when showing.
    func toggleOverlay<Content: View>(with view: Content) {
        if isVisible {
            hideOverlay()
        } else {
            showOverlay(with: view)
        }
    }

    // MARK: - Content Updates

    /// Convenience method for appending a segment to an overlay view that is backed
    /// by an ``OverlayView``. The caller should maintain the canonical segment array
    /// and pass updated state through SwiftUI bindings; this method exists as a
    /// programmatic bridge for non-SwiftUI callers.
    ///
    /// - Parameter segment: The display segment to add.
    /// - Parameter segments: An inout reference to the segment array owned by the caller.
    func addSegment(_ segment: DisplaySegment, to segments: inout [DisplaySegment]) {
        segments.append(segment)
    }

    // MARK: - Panel Factory

    private func createPanel() -> OverlayPanel {
        let newPanel = OverlayPanel()

        // Re-sync visibility state when the user closes the panel via the title-bar button.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isVisible = false
            }
        }

        return newPanel
    }
}
