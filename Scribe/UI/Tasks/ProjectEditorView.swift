import SwiftUI

/// Sheet for creating a new project or editing an existing one. Slice 4 keeps
/// the schema minimal: name + a small swatch palette + an SF Symbol name.
struct ProjectEditorView: View {

    let mode: ProjectEditorMode
    let onCommit: (_ name: String, _ color: String?, _ icon: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedColor: String?
    @State private var icon: String?

    /// Curated swatch palette — keeps the editor opinionated. Free-form hex
    /// can come later if it ever matters.
    static let swatches: [String] = [
        "#FF453A", "#FF9F0A", "#FFD60A", "#30D158",
        "#64D2FF", "#0A84FF", "#5E5CE6", "#BF5AF2"
    ]

    init(mode: ProjectEditorMode, onCommit: @escaping (_ name: String, _ color: String?, _ icon: String?) -> Void) {
        self.mode = mode
        self.onCommit = onCommit
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _selectedColor = State(initialValue: nil)
            _icon = State(initialValue: nil)
        case .edit(let project):
            _name = State(initialValue: project.name)
            _selectedColor = State(initialValue: project.color)
            _icon = State(initialValue: project.icon)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Project name", text: $name)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.md), count: 8), spacing: DesignTokens.Spacing.md) {
                        SwatchCell(color: nil, selected: selectedColor == nil) {
                            selectedColor = nil
                        }
                        ForEach(Self.swatches, id: \.self) { hex in
                            SwatchCell(color: hex, selected: selectedColor == hex) {
                                selectedColor = hex
                            }
                        }
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
                Section("Icon") {
                    SymbolPickerGrid(selection: $icon)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCommit(trimmed, selectedColor, icon)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 400, idealHeight: 460)
    }

    private var title: String {
        switch mode {
        case .create: return "New project"
        case .edit:   return "Edit project"
        }
    }
}

private struct SwatchCell: View {
    let color: String?
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(swatchFill)
                    .frame(width: 28, height: 28)
                if selected {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .frame(width: 32, height: 32)
                }
                if color == nil {
                    Image(systemName: "slash.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(color ?? "No color")
    }

    private var swatchFill: Color {
        if let hex = color { return Color(hex: hex) ?? .gray }
        return DesignTokens.Palette.fill(.strong)
    }
}

// MARK: - Hex parsing

extension Color {
    /// Parse a `#RRGGBB` (or `#RRGGBBAA`) hex string into a `Color`. Returns
    /// nil for malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8)  & 0xFF) / 255
            b = Double( v        & 0xFF) / 255
            a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8)  & 0xFF) / 255
            a = Double( v        & 0xFF) / 255
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
