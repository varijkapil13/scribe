import SwiftUI

extension DesignTokens.Palette {
    static let overdue = Color(light: 0xB4570B, dark: 0xF0A35E)
}

extension DesignTokens {
    /// List-pane metrics and type shared by Tasks and Meetings.
    enum QuietList {
        static let rowHeight: CGFloat = 36
        static let sectionSpacing: CGFloat = 20
        static let gutter: CGFloat = 20

        static let titleFont = Font.system(size: 18, weight: .semibold)
        static let countFont = Font.system(size: 12).monospacedDigit()
        static let sectionFont = Font.system(size: 12, weight: .semibold)
        static let rowTitleFont = Font.system(size: 13)
        static let rowMetaFont = Font.system(size: 12).monospacedDigit()
    }
}

/// "Title  38 open" header used atop list panes (tasks, recordings, people).
struct QuietListHeader<Trailing: View>: View {
    let title: String
    var count: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.QuietList.titleFont)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)
            if let count {
                Text(count)
                    .font(DesignTokens.QuietList.countFont)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension QuietListHeader where Trailing == EmptyView {
    init(title: String, count: String? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

extension View {
    /// Sentence-case 12pt semibold tertiary section label ("Overdue  3").
    func quietListSectionHeader() -> some View {
        font(DesignTokens.QuietList.sectionFont)
            .foregroundStyle(DesignTokens.Palette.textTertiary)
    }

    /// Selected list row: neutral selection fill, rounded to the row radius.
    func quietListRowBackground(selected: Bool, hovered: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .fill(selected
                      ? DesignTokens.Palette.selectionFill
                      : (hovered ? DesignTokens.Palette.quietFill.opacity(0.6) : Color.clear))
        )
    }

    /// Raised surface with a hairline border (cards, inspector, playback bar).
    func quietListRaised(radius: CGFloat = DesignTokens.Radius.md) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DesignTokens.Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(DesignTokens.Palette.hairline, lineWidth: 1)
        )
    }
}
