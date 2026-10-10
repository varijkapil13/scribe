import AppKit
import SwiftUI

/// Small floating pill shown near the bottom of the screen while dictating.
///
/// It's a non-activating panel that ignores the mouse, so it never takes
/// keyboard focus from the app the text will be typed into.
@MainActor
final class DictationHUD {

    private let controller: DictationController
    private var panel: NSPanel?

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationHUDView(controller: controller))
        return panel
    }

    /// Bottom-center of the screen with the mouse (where the user is working).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48))
    }
}

private struct DictationHUDView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            indicator
                .frame(width: 28, height: 28)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(captionIsPlaceholder ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(width: 420, height: 64)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation: \(caption)")
    }

    @ViewBuilder
    private var indicator: some View {
        switch controller.state {
        case .preparing, .processing:
            ProgressView().controlSize(.small)
        case .listening:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.25))
                    .scaleEffect(0.6 + CGFloat(controller.level) * 0.8)
                    .animation(.easeOut(duration: 0.1), value: controller.level)
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
        case .finished, .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        switch controller.state {
        case .preparing:  return "Getting ready…"
        case .listening:  return controller.liveText.isEmpty ? "Listening…" : controller.liveText
        case .processing: return controller.liveText.isEmpty ? "Finishing…" : controller.liveText
        case .finished(let message): return message
        case .idle: return ""
        }
    }

    private var captionIsPlaceholder: Bool {
        switch controller.state {
        case .listening, .processing: return controller.liveText.isEmpty
        default: return true
        }
    }
}
