import SwiftUI

// MARK: - Liquid Glass (macOS 27) — the single home of the glass APIs
//
// Every use of the system Liquid Glass APIs (`glassEffect`, `Glass`,
// `GlassEffectContainer`, the `.glass` / `.glassProminent` button styles and
// `safeAreaBar`) is funnelled through the small helpers in this file. If an SDK
// revision renames or reshapes one of them, the compile fix is here and only
// here — call sites use the `scribe…` wrappers.
//
// Discipline (unchanged from the earlier material tokens): glass is for the
// floating navigation/control layer only — the live recording controller, the
// dictation HUD, the format bubble, the slash menu, the command bar, toasts and
// the Quick Capture panel. Content (note editor, transcript body, task rows)
// stays plain, and sidebars / toolbars / inspectors get the system material by
// NOT painting their own background.
//
// Accessibility: under Reduce Transparency or Increase Contrast every helper
// collapses to an opaque elevated surface with a contrast-aware hairline.

/// Pure accessibility policy for glass surfaces (unit-tested).
enum ScribeGlassPolicy {
    /// Whether a glass surface must fall back to an opaque fill.
    nonisolated static func prefersOpaque(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        reduceTransparency || increasedContrast
    }
}

// MARK: - Raw API isolation (the only direct glass call sites)

extension View {
    /// The ONLY direct `glassEffect` call in the app. Regular glass, optionally
    /// tinted (pass `nil` for untinted) and interactive (reacts to pointer).
    func scribeLiquidGlass<S: Shape>(in shape: S, tint: Color?, interactive: Bool) -> some View {
        glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    }

    /// The ONLY `safeAreaBar` call: a custom bar pinned to a scroll view's
    /// edge that participates in the system scroll-edge effect, so it needs no
    /// painted background of its own (the sidebar material shows through).
    func scribeEdgeBar<Bar: View>(_ edge: VerticalEdge,
                                  @ViewBuilder content: () -> Bar) -> some View {
        // Build the bar eagerly so forwarding works whether or not the SDK
        // declares `safeAreaBar`'s content closure as escaping.
        let bar = content()
        return safeAreaBar(edge: edge, spacing: 0) { bar }
    }
}

/// Groups neighbouring glass shapes so they blend and morph together (wraps
/// `GlassEffectContainer`). Harmless when the children fall back to opaque.
struct ScribeGlassGroup<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat?, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

// MARK: - Floating glass surface

private struct ScribeFloatingGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if ScribeGlassPolicy.prefersOpaque(reduceTransparency: reduceTransparency,
                                           increasedContrast: contrast == .increased) {
            content
                .background(DesignTokens.Palette.surfaceElevated, in: shape)
                .overlay {
                    shape.stroke(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
                }
        } else {
            // Glass draws its own edge highlight and depth shadow — no custom
            // border or drop shadow on this path.
            content.scribeLiquidGlass(in: shape, tint: tint, interactive: interactive)
        }
    }
}

extension View {
    /// Backs a floating control surface (HUD, bubble, toast, panel) with
    /// Liquid Glass in `shape`, falling back to an opaque elevated fill under
    /// Reduce Transparency / Increase Contrast.
    func scribeFloatingGlass<S: Shape>(in shape: S,
                                       tint: Color? = nil,
                                       interactive: Bool = false) -> some View {
        modifier(ScribeFloatingGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }
}

// MARK: - Glass buttons

private struct ScribeGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        } else {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        }
    }
}

extension View {
    /// Glass button style for buttons that float over content. `prominent`
    /// is for the single primary action of a floating surface. Falls back to
    /// the bordered styles under Reduce Transparency.
    func scribeGlassButton(prominent: Bool) -> some View {
        modifier(ScribeGlassButtonModifier(prominent: prominent))
    }
}
