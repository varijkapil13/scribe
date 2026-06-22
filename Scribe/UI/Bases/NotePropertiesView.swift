import SwiftUI

/// Self-contained, reusable editor for a note's typed frontmatter properties —
/// Scribe's analogue to Obsidian's "properties" block at the top of a note.
///
/// This component owns no storage of its own: it is bound to a `[NoteProperty]`
/// and reports every mutation through an `onCommit` callback so the host
/// (a note editor, a Base inspector, or the `#Preview`) decides how to persist.
/// That keeps it trivially composable and lets the editor-rewrite PR wire it
/// into `NoteEditorView` later without this view needing to change.
struct NotePropertiesView: View {

    @Binding var properties: [NoteProperty]
    /// Called after any add/remove/edit, with the full updated list, so the
    /// host can debounce + persist.
    var onCommit: ([NoteProperty]) -> Void

    /// Distinct existing values per key, used to power `select` suggestions.
    var optionSuggestions: [String: [String]] = [:]

    /// When false the internal "Properties" header is hidden (the host already
    /// labels the block — e.g. the note meta-bar chip), and a compact "Add
    /// property" button is shown instead so adding still works.
    var showsHeader: Bool = true

    @State private var isAddingProperty = false
    @State private var newKey = ""
    @State private var newType: PropertyType = .text

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if showsHeader { header }

            if properties.isEmpty && !isAddingProperty {
                emptyState
            } else {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach($properties) { $property in
                        PropertyRow(
                            property: $property,
                            suggestions: optionSuggestions[property.key] ?? [],
                            onChange: { onCommit(properties) },
                            onRemove: { remove(property) }
                        )
                    }
                }
            }

            if isAddingProperty {
                addPropertyForm
            } else if !showsHeader {
                addButton
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    /// Compact "Add property" affordance shown when the header (which normally
    /// carries the add control) is hidden — e.g. embedded under the note meta bar.
    private var addButton: some View {
        Button {
            withAnimation(DesignTokens.Motion.snappy) {
                isAddingProperty = true
                newKey = ""
                newType = .text
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "plus.circle")
                Text("Add property")
            }
            .font(DesignTokens.Typography.callout)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Properties")
                .font(DesignTokens.Typography.eyebrow)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(DesignTokens.Motion.snappy) {
                    isAddingProperty.toggle()
                    if isAddingProperty {
                        newKey = ""
                        newType = .text
                    }
                }
            } label: {
                Image(systemName: isAddingProperty ? "minus.circle" : "plus.circle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isAddingProperty ? "Cancel" : "Add property")
        }
    }

    private var emptyState: some View {
        Text("No properties yet")
            .font(DesignTokens.Typography.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Add form

    private var addPropertyForm: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Property name", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitNewProperty)

            Picker("Type", selection: $newType) {
                ForEach(PropertyType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Button("Add", action: commitNewProperty)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedNewKey.isEmpty || keyExists(trimmedNewKey))
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
    }

    // MARK: - Mutations

    private var trimmedNewKey: String {
        newKey.trimmingCharacters(in: .whitespaces)
    }

    private func keyExists(_ key: String) -> Bool {
        properties.contains { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    private func commitNewProperty() {
        let key = trimmedNewKey
        guard !key.isEmpty, !keyExists(key) else { return }
        let value = NotePropertiesView.defaultValue(for: newType)
        properties.append(NoteProperty(key: key, value: value))
        onCommit(properties)
        withAnimation(DesignTokens.Motion.snappy) {
            isAddingProperty = false
            newKey = ""
        }
    }

    private func remove(_ property: NoteProperty) {
        withAnimation(DesignTokens.Motion.snappy) {
            properties.removeAll { $0.id == property.id }
        }
        onCommit(properties)
    }

    /// Sensible empty value for a freshly added property of each type.
    static func defaultValue(for type: PropertyType) -> PropertyValue {
        switch type {
        case .text:     return .text("")
        case .number:   return .number(0)
        case .date:     return .date(Date())
        case .checkbox: return .checkbox(false)
        case .list:     return .list([])
        case .select:   return .select("")
        }
    }
}

// MARK: - Property row

/// One editable property line: name + type badge + a type-appropriate editor +
/// a remove affordance.
private struct PropertyRow: View {
    @Binding var property: NoteProperty
    var suggestions: [String]
    var onChange: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: property.type.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(property.key)
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            editor

            Spacer(minLength: 0)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove property")
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    @ViewBuilder
    private var editor: some View {
        switch property.value {
        case .text(let s):
            TextField("Empty", text: Binding(
                get: { s },
                set: { property.value = .text($0); onChange() }
            ))
            .textFieldStyle(.roundedBorder)

        case .select(let s):
            HStack(spacing: DesignTokens.Spacing.xs) {
                TextField("Empty", text: Binding(
                    get: { s },
                    set: { property.value = .select($0); onChange() }
                ))
                .textFieldStyle(.roundedBorder)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { option in
                            Button(option) {
                                property.value = .select(option)
                                onChange()
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
            }

        case .number(let n):
            TextField("0", value: Binding(
                get: { n },
                set: { property.value = .number($0); onChange() }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)

        case .checkbox(let b):
            Toggle("", isOn: Binding(
                get: { b },
                set: { property.value = .checkbox($0); onChange() }
            ))
            .labelsHidden()

        case .date(let d):
            DatePicker("", selection: Binding(
                get: { d },
                set: { property.value = .date($0); onChange() }
            ), displayedComponents: .date)
            .labelsHidden()

        case .list(let xs):
            TextField("comma, separated", text: Binding(
                get: { xs.joined(separator: ", ") },
                set: {
                    let items = $0.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    property.value = .list(items)
                    onChange()
                }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Preview

#Preview("Note Properties") {
    StatefulPreviewWrapper([
        NoteProperty(key: "status", value: .select("In Progress")),
        NoteProperty(key: "priority", value: .number(2)),
        NoteProperty(key: "due", value: .date(Date())),
        NoteProperty(key: "starred", value: .checkbox(true)),
        NoteProperty(key: "topics", value: .list(["swift", "macos"])),
        NoteProperty(key: "summary", value: .text("A short note about Bases.")),
    ]) { binding in
        NotePropertiesView(
            properties: binding,
            onCommit: { print("committed \($0.count) properties") },
            optionSuggestions: ["status": ["Todo", "In Progress", "Done"]]
        )
        .frame(width: 460)
    }
}

/// Small helper that gives `#Preview` a mutable binding to drive the view.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}
