import SwiftUI

/// Transient error banner shown over the main window. Driven by
/// `AppState.lastError`. Auto-dismisses after a few seconds; can be dismissed
/// manually via the close button.
///
/// Lives at the top of the detail pane so it sits inside the window chrome
/// instead of obscuring the toolbar — and uses the recording-red palette so
/// failures feel as urgent as they are without flashing system alerts at the
/// user for everything.
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Palette.recording)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Something went wrong")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.recording.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        .padding(DesignTokens.Spacing.md)
        .transition(
            .move(edge: .top)
                .combined(with: .opacity)
        )
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Pins an `ErrorBanner` to the top of the host view whenever
    /// `AppState.lastError` is non-nil. Auto-clears after 6 seconds.
    func errorBanner(_ appState: AppState) -> some View {
        modifier(ErrorBannerModifier(appState: appState))
    }
}

private struct ErrorBannerModifier: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = appState.lastError {
                    ErrorBanner(message: message) {
                        withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                            appState.lastError = nil
                        }
                    }
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if appState.lastError == message {
                            withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                                appState.lastError = nil
                            }
                        }
                    }
                }
            }
    }
}
