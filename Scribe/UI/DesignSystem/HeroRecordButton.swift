import SwiftUI

/// Oversized primary "Record" affordance used on the welcome / empty state.
/// Capsule-shaped, heavy weight, red-tinted — the single primary CTA on the
/// screen so there's no ambiguity about what to do next.
struct HeroRecordButton: View {

    let isRecording: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: isRecording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text(isRecording ? "Stop Recording" : "Start Recording")
                    .font(.system(.title3, weight: .semibold))
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.vertical, DesignTokens.Spacing.md + 2)
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(DesignTokens.Palette.recording)
                    .shadow(color: DesignTokens.Palette.recording.opacity(isHovering ? 0.35 : 0.22),
                            radius: isHovering ? 18 : 10,
                            x: 0, y: isHovering ? 8 : 4)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1.0 : (isPressed ? 0.97 : (isHovering ? 1.015 : 1.0)))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pressAction(onPress: { isPressed = true }, onRelease: { isPressed = false })
        .animation(.easeOut(duration: DesignTokens.Motion.fast), value: isHovering)
        .animation(.easeOut(duration: DesignTokens.Motion.fast), value: isPressed)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

// MARK: - Press-tracking modifier

/// Simple helper that lets a plain Button expose press-down / press-up hooks
/// for scale feedback without rebuilding `ButtonStyle`.
private struct PressActionsModifier: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }
}

extension View {
    fileprivate func pressAction(onPress: @escaping () -> Void,
                                 onRelease: @escaping () -> Void) -> some View {
        modifier(PressActionsModifier(onPress: onPress, onRelease: onRelease))
    }
}
