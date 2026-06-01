import SwiftUI

/// Curated SF Symbol grid picker for project icons. Replaces the old raw
/// "type the symbol name" `TextField` (which silently produced a blank icon on
/// any typo) with a visual, keyboard-navigable `LazyVGrid` of common choices.
///
/// Accessibility: each cell is `.focusable` with a visible focus ring, exposes
/// a VoiceOver label + `.isSelected` trait, and the whole grid is operable with
/// arrow keys + Return.
struct SymbolPickerGrid: View {

    @Binding var selection: String?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent
    @FocusState private var focusedSymbol: String?

    /// Curated, opinionated palette of project-appropriate glyphs. Free-form
    /// entry can return later if it's ever missed.
    static let symbols: [String] = [
        "folder", "briefcase", "house", "tag", "star", "flag",
        "book", "graduationcap", "cart", "creditcard", "airplane", "car",
        "heart", "leaf", "bolt", "flame", "drop", "globe",
        "hammer", "wrench.and.screwdriver", "paintbrush", "pencil", "doc.text", "calendar",
        "person.2", "bubble.left", "envelope", "phone", "gift", "trophy"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.sm), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.sm) {
            cell(name: nil, systemImage: "slash.circle", label: "No icon")
            ForEach(Self.symbols, id: \.self) { name in
                cell(name: name, systemImage: name, label: name)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cell(name: String?, systemImage: String, label: String) -> some View {
        let isSelected = selection == name
        let isFocused = focusedSymbol == (name ?? "__none__")
        Button {
            selection = name
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.white : .secondary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(isSelected
                              ? accent
                              : DesignTokens.Palette.fill(.hover, contrast: contrast))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .strokeBorder(isFocused ? accent : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedSymbol, equals: name ?? "__none__")
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
