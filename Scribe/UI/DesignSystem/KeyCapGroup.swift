import SwiftUI

/// Tiny inline "keyboard key caps" renderer for shortcut hints.
///
/// In its own file (kept in the SwiftPM test target) because both an excluded
/// view (`MainWindowView`) and a kept view (`UniversalSearchView`) use it.
struct KeyCapGroup: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                            .fill(DesignTokens.Palette.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                            .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                    )
            }
        }
    }
}
