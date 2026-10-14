import SwiftUI

extension DesignTokens {
    enum Notes {
        static let listWidth: CGFloat = 280
        static let listMinWidth: CGFloat = 220
        static let listMaxWidth: CGFloat = 340
        static let inspectorWidth: CGFloat = 236

        static let rowRadius: CGFloat = 10
        static let rowVerticalPadding: CGFloat = 10
        static let rowHorizontalPadding: CGFloat = 12
        static let listInset: CGFloat = 8

        static let listTitle = Font.system(size: 17, weight: .semibold)
        static let listCount = Font.system(size: 12)
        static let rowTitle = Font.system(size: 14, weight: .semibold)
        static let rowSnippet = Font.system(size: 13)
        static let rowDate = Font.system(size: 12)

        static let meta = Font.system(size: 12)
        static let chip = Font.system(size: 11.5, weight: .medium)
        static let inspectorHeader = Font.system(size: 11, weight: .semibold)
        static let inspectorBody = Font.system(size: 12.5)

        static let titleSize: CGFloat = 30
        static let editorGutter: CGFloat = 44
    }
}

extension View {
    /// The selected note-list row: a raised card with a hairline inset border
    /// and a barely-there shadow.
    func noteRowSelectedCard(_ isSelected: Bool, isHovered: Bool) -> some View {
        modifier(NoteRowCardModifier(isSelected: isSelected, isHovered: isHovered))
    }

    /// Small capsule used for note tags (accent tint) and project (quiet fill).
    func noteChip(tinted: Bool) -> some View {
        self
            .font(DesignTokens.Notes.chip)
            .foregroundStyle(tinted ? DesignTokens.Palette.accent : DesignTokens.Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tinted ? DesignTokens.Palette.accent.opacity(0.10) : DesignTokens.Palette.quietFill)
            )
    }
}

private struct NoteRowCardModifier: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Notes.rowRadius, style: .continuous)
        content
            .background {
                if isSelected {
                    shape
                        .fill(DesignTokens.Palette.raised)
                        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
                        .overlay(shape.strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1))
                } else if isHovered {
                    shape.fill(DesignTokens.Palette.selectionFill)
                }
            }
    }
}
