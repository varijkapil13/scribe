import SwiftUI

/// A reusable input-level meter — a short row of rounded bars that fill from
/// the leading edge as `level` (0…1) rises. Drives off the smoothed level
/// published by ``AudioSessionManager`` (`inputLevel` / `systemLevel`).
///
/// Accessibility:
/// - The individual bars are decorative (`.accessibilityHidden(true)`); the
///   container exposes a single coarse value ("Input level: high / medium /
///   low / silent") so VoiceOver users get a meaningful reading without a
///   per-bar firehose.
/// - Under Reduce Motion the meter renders a single static proportional fill
///   (no oscillation), so it never animates distractingly.
struct LevelMeterView: View {

    /// Smoothed level in 0…1.
    let level: Float
    /// Tint of the lit bars. Defaults to the resolved chrome accent.
    var tint: Color?
    /// Number of bars in the row.
    var barCount: Int = 12
    /// Bar dimensions.
    var barWidth: CGFloat = 3
    var barHeight: CGFloat = 14
    var spacing: CGFloat = 2
    /// An optional source label folded into the VoiceOver value
    /// (e.g. "You", "Remote"), so a dual meter reads distinctly.
    var sourceLabel: String?

    @Environment(\.scribeAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var resolvedTint: Color { tint ?? accent }

    var body: some View {
        Group {
            if reduceMotion {
                staticFill
            } else {
                bars
            }
        }
        .frame(height: barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sourceLabel.map { "\($0) level" } ?? "Input level")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Animated bars

    private var bars: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(barFill(at: index))
                    .frame(width: barWidth, height: barHeight)
            }
        }
        .accessibilityHidden(true)
        // The level itself already arrives pre-smoothed at ~13 Hz, so a short
        // crossfade keeps the lit/unlit transition from stepping harshly.
        .scribeAnimation(.snappy, value: litBars)
    }

    /// How many bars should be lit for the current level.
    private var litBars: Int {
        let clamped = min(max(level, 0), 1)
        return Int((clamped * Float(barCount)).rounded())
    }

    private func barFill(at index: Int) -> Color {
        index < litBars ? resolvedTint : DesignTokens.Palette.fill(.hover, contrast: contrast)
    }

    // MARK: - Static (Reduce Motion) fill

    private var staticFill: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.Palette.fill(.hover, contrast: contrast))
                Capsule()
                    .fill(resolvedTint)
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: barWidth * 2)
        .frame(maxWidth: CGFloat(barCount) * (barWidth + spacing))
        .accessibilityHidden(true)
    }

    // MARK: - Accessibility value

    private var accessibilityValue: String {
        switch level {
        case ..<0.04:  return "silent"
        case ..<0.33:  return "low"
        case ..<0.66:  return "medium"
        default:       return "high"
        }
    }
}

#if DEBUG
#Preview("Level meter") {
    VStack(spacing: 16) {
        LevelMeterView(level: 0.0)
        LevelMeterView(level: 0.25)
        LevelMeterView(level: 0.6, tint: DesignTokens.Palette.speakerRemote, sourceLabel: "Remote")
        LevelMeterView(level: 0.95)
    }
    .padding(40)
}
#endif
