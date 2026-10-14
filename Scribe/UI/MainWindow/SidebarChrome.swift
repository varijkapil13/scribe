// Scribe/UI/MainWindow/SidebarChrome.swift
//
// Sidebar chrome: the destination row, its label style, section headers and a
// precomputed notebook-tree index.

import SwiftUI

// MARK: - Sidebar row

/// A sidebar destination row: 30pt tall, a quiet rounded selection fill and a
/// hover wash, fully clickable.
///
/// Built on an explicit `Button` rather than `List(selection:)`: in this
/// window's `NavigationSplitView`, `List` row-clicks never engage (neither
/// `NavigationLink(value:)` nor `.tag()` fire the selection), and native `List`
/// rows show no hover at all.
struct SidebarRow<Content: View>: View {
    var isSelected: Bool
    /// Leading inset for tree depth — applied to the content, so the highlight
    /// still spans the full row width.
    var indent: CGFloat = 0
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            content()
                .labelStyle(SidebarLabelStyle(isSelected: isSelected))
                .font(DesignTokens.Typography.sidebarRow.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .padding(.leading, indent)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.Metrics.sidebarRowHeight, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .fill(fillColor)
        )
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) { isHovering = hovering }
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.sm,
                                  bottom: 0, trailing: DesignTokens.Spacing.sm))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var fillColor: Color {
        if isSelected {
            return contrast == .increased
                ? DesignTokens.Palette.fill(.strong, contrast: contrast)
                : DesignTokens.Palette.selectionFill
        }
        if isHovering { return DesignTokens.Palette.fill(.hover, contrast: contrast) }
        return .clear
    }
}

/// Grey icon that takes the accent only when its row is selected. An icon
/// that sets its own foreground style (a project colour) keeps it.
struct SidebarLabelStyle: LabelStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            configuration.icon
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? DesignTokens.Palette.accent : DesignTokens.Palette.textSecondary)
                .frame(width: 18)
            configuration.title
                .lineLimit(1)
        }
    }
}

struct SidebarCount: View {
    let value: Int

    var body: some View {
        if value > 0 {
            Text(value, format: .number)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        }
    }
}

// MARK: - Section header

/// 11pt semibold tertiary section title. Clicking it collapses the section
/// when an expansion binding is given; `accessory` sits at the trailing edge.
struct SidebarSectionHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    var isExpanded: Binding<Bool>?
    @ViewBuilder var accessory: () -> Accessory

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button {
                guard let isExpanded else { return }
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(title)
                        .font(DesignTokens.Typography.sidebarHeader)
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                    if let isExpanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                            .opacity(isHovering || !isExpanded.wrappedValue ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded.map { $0.wrappedValue ? "Expanded" : "Collapsed" } ?? "")
            Spacer(minLength: 0)
            accessory()
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.leading, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.sm)
        .onHover { isHovering = $0 }
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(title: LocalizedStringKey, isExpanded: Binding<Bool>? = nil) {
        self.init(title: title, isExpanded: isExpanded) { EmptyView() }
    }
}

struct SidebarHeaderButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Notebook tree index

/// Precomputed parent → children and notebook → notes lookups so the notebook
/// tree never re-scans the full notebook/note arrays at every node. Built once
/// per sidebar render — O(N + M) — replacing the previous per-row `.filter`
/// scans that were O(M · N) across the whole tree.
struct NotebookTreeIndex {
    private let childNotebooks: [String?: [Notebook]]
    private let notesByNotebook: [String: [Note]]

    init(notebooks: [Notebook], notes: [Note]) {
        var children: [String?: [Notebook]] = [:]
        for notebook in notebooks.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            children[notebook.parentId, default: []].append(notebook)
        }
        var byNotebook: [String: [Note]] = [:]
        for note in notes where !note.isDailyNote {
            guard let notebookId = note.notebookId else { continue }
            byNotebook[notebookId, default: []].append(note)
        }
        for key in byNotebook.keys {
            byNotebook[key]?.sort { $0.updatedAt > $1.updatedAt }
        }
        childNotebooks = children
        notesByNotebook = byNotebook
    }

    /// Child notebooks of `parentId` (nil = roots), already sort-ordered.
    func children(of parentId: String?) -> [Notebook] { childNotebooks[parentId] ?? [] }

    /// Non-daily notes filed directly in `notebookId`, newest first.
    func notes(in notebookId: String) -> [Note] { notesByNotebook[notebookId] ?? [] }

    /// Whether a notebook has sub-notebooks (drives the chevron).
    func hasChildren(_ notebookId: String) -> Bool {
        !(childNotebooks[notebookId] ?? []).isEmpty
    }
}
