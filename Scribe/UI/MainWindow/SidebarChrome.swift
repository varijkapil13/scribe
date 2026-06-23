// Scribe/UI/MainWindow/SidebarChrome.swift
//
// Modern sidebar chrome: the surface switcher, a reusable hover/selection row
// highlight, and a precomputed notebook-tree index. Extracted from
// MainWindowView so the sidebar's look-and-feel lives in one place.

import SwiftUI

// MARK: - Surface switcher

/// Capture / Notes / Tasks switcher with an animated selection pill and hover
/// feedback. Replaces the stock `.pickerStyle(.segmented)` control, which read
/// as a chunky toolbar segment and — backed by `.bar` material — visually
/// merged with the window's titlebar. This blends with the sidebar instead and
/// slides its selection pill between segments.
struct SidebarSurfaceSwitcher: View {
    let current: Surface
    let onSelect: (Surface) -> Void

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Surface.allCases) { surface in
                SidebarSurfaceSegment(
                    surface: surface,
                    isSelected: surface == current,
                    namespace: pill,
                    action: { onSelect(surface) }
                )
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous).fill(DesignTokens.Palette.fill(.hover))
        )
        .animation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion), value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Surface")
        .accessibilityHint("Switch between Capture, Notes and Tasks")
    }
}

private struct SidebarSurfaceSegment: View {
    let surface: Surface
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: surface.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(surface.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .lineLimit(1)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Palette.surfaceElevated)
                        .shadow(color: .black.opacity(DesignTokens.Shadow.hairline.opacity),
                                radius: DesignTokens.Shadow.hairline.radius,
                                y: DesignTokens.Shadow.hairline.y)
                        .matchedGeometryEffect(id: "surfaceSelection", in: namespace)
                } else if isHovering {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Palette.fill(.hover))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(surface.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Row highlight (hover + selection)

/// Rounded hover + selection highlight for the custom sidebar rows (the
/// notebook tree). Gives every row a modern pill that lights up on hover and
/// fills with the accent tint when its destination is selected — the feedback
/// the plain-button tree rows were missing.
private struct SidebarRowHighlight: ViewModifier {
    var isSelected: Bool
    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) {
                        isHovering = hovering
                    }
                }
            }
    }

    private var fill: Color {
        if isSelected {
            return DesignTokens.Palette.accentFill(.selected, accent: .accentColor, contrast: contrast)
        }
        if isHovering {
            return DesignTokens.Palette.fill(.hover, contrast: contrast)
        }
        return .clear
    }
}

extension View {
    /// Applies the sidebar's modern hover + selection pill to a custom row.
    func sidebarRowHighlight(isSelected: Bool = false) -> some View {
        modifier(SidebarRowHighlight(isSelected: isSelected))
    }
}

// MARK: - Sidebar row

/// A sidebar destination row with a full-width rounded selection fill + hover
/// highlight and a fully clickable row.
///
/// Built on an explicit `Button` rather than `List(selection:)`: in this
/// window's `NavigationSplitView`, `List` row-clicks never engage (neither
/// `NavigationLink(value:)` nor `.tag()` fire the selection), and native `List`
/// rows show no hover at all. This replicates the macOS sidebar look — a
/// rounded, accent-tinted selection that spans the row (minus a small margin),
/// plus a subtle hover — reliably, and is used for every sidebar row so the
/// whole sidebar is consistent.
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
                // White content on the solid accent fill (the native sidebar
                // selection look) — primary otherwise.
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.leading, indent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(fillColor)
        )
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) { isHovering = hovering }
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: DesignTokens.Spacing.sm,
                                  bottom: 1, trailing: DesignTokens.Spacing.sm))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var fillColor: Color {
        // Solid accent for the selected row (matches the native macOS sidebar
        // selection), a subtle neutral wash on hover.
        if isSelected { return .accentColor }
        if isHovering { return DesignTokens.Palette.fill(.hover, contrast: contrast) }
        return .clear
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

    /// Whether a notebook has any sub-notebooks or notes (drives the chevron).
    func hasChildren(_ notebookId: String) -> Bool {
        !(childNotebooks[notebookId] ?? []).isEmpty || !(notesByNotebook[notebookId] ?? []).isEmpty
    }
}
