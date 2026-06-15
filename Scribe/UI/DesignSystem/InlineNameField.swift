import SwiftUI

/// Inline editable text field for sidebar rows (notebook create / rename).
/// Commits on Return, cancels on Escape.
///
/// In its own file (kept in the SwiftPM test target) because both an excluded
/// view (`MainWindowView`) and a kept view (`NotebookTreeView`) use it.
struct InlineNameField: View {
    @Binding var text: String
    let placeholder: String
    let systemImage: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .focused($isFocused)
                .onSubmit { onCommit() }
                .onExitCommand { onCancel() }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .listRowBackground(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .padding(.horizontal, -DesignTokens.Spacing.xs)
        )
        .onAppear { isFocused = true }
    }
}
