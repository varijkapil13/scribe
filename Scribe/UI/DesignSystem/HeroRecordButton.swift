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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

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
                    .fill(fillStyle)
                    .shadow(color: DesignTokens.Palette.recording.opacity(isHovering ? 0.35 : 0.22),
                            radius: isHovering ? 18 : 10,
                            x: 0, y: isHovering ? 8 : 4)
            )
            .overlay(
                // Top-edge highlight gives the pill a physical, light-from-above
                // read (Craft/IINA glass). Decorative only — flattened under
                // Increase Contrast / Reduce Transparency.
                Capsule()
                    .strokeBorder(edgeHighlight, lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1.0 : (isPressed ? 0.97 : (isHovering ? 1.015 : 1.0)))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pressAction(onPress: { isPressed = true }, onRelease: { isPressed = false })
        .scribeAnimation(DesignTokens.Motion.snappy, value: isHovering)
        .scribeAnimation(DesignTokens.Motion.snappy, value: isPressed)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    /// True when decorative depth (gradient fill + edge highlight) is allowed.
    private var decorative: Bool { !reduceTransparency && contrast != .increased }

    private var fillStyle: AnyShapeStyle {
        let base = DesignTokens.Palette.recording
        guard decorative else { return AnyShapeStyle(base) }
        return AnyShapeStyle(LinearGradient(
            colors: [base, base.opacity(0.88)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    private var edgeHighlight: LinearGradient {
        LinearGradient(
            colors: decorative
                ? [Color.white.opacity(0.30), Color.white.opacity(0.10)]
                : [Color.white.opacity(0.15), Color.white.opacity(0.15)],
            startPoint: .top, endPoint: .bottom
        )
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
