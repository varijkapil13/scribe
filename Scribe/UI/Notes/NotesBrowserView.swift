// Scribe/UI/Notes/NotesBrowserView.swift
import SwiftUI

/// Two-pane notes browser: note list on the left, detail on the right.
/// Used for All Notes / Unfiled / Notebook scopes. For `.all` and `.inbox`
/// the list pane offers a segmented chip to toggle between the two so those
/// filters don't need to take up dedicated sidebar rows.
struct NotesBrowserView: View {
    let initialScope: NoteListScope

    /// Craft-style drill-down stack of note IDs. The list selects the root
    /// (`navPath.first`); clicking a wiki-link/backlink inside a note pushes a
    /// card; the breadcrumb + Back pop it. `navPath.last` is the displayed note.
    @State private var navPath: [String] = []
    @State private var currentNote: Note?
    @State private var titlesById: [String: String] = [:]
    /// Direction of the last navigation, so the card transition slides the
    /// right way (push → in from trailing; pop → in from leading).
    @State private var goingBack = false
    @State private var activeScope: NoteListScope

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(scope: NoteListScope) {
        self.initialScope = scope
        _activeScope = State(initialValue: scope)
    }

    private var showsScopeChips: Bool {
        switch initialScope {
        case .all, .inbox: return true
        case .notebook:    return false
        }
    }

    /// List selection drives the ROOT of the nav stack (resets any drill-down).
    private var listSelection: Binding<String?> {
        Binding(
            get: { navPath.first },
            set: { newValue in
                goingBack = false
                navPath = newValue.map { [$0] } ?? []
            }
        )
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if showsScopeChips {
                    NotesScopeChipBar(activeScope: $activeScope)
                }
                NoteListView(scope: activeScope, selectedNoteId: listSelection)
                    .id(NoteListScopeID(scope: activeScope))
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)

            detailColumn
        }
        .task(id: navPath.last) {
            guard let id = navPath.last else { currentNote = nil; return }
            let note = try? NoteStore.shared.fetchNote(id: id)
            currentNote = note
            if let note {
                titlesById[note.id] = note.title.isEmpty ? "Untitled" : note.title
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        VStack(spacing: 0) {
            if navPath.count > 1 {
                breadcrumbBar
            }
            Group {
                if let note = currentNote, note.id == navPath.last {
                    NoteDetailView(note: note, onNavigate: { push($0) })
                        .id(note.id)
                        .transition(cardTransition)
                } else if navPath.isEmpty {
                    emptyState
                } else {
                    Color.clear  // brief gap while the next card loads
                }
            }
            .animation(DesignTokens.Motion.resolve(DesignTokens.Motion.gentle, reduceMotion: reduceMotion),
                       value: currentNote?.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: goingBack ? .leading : .trailing).combined(with: .opacity),
            removal:   .move(edge: goingBack ? .trailing : .leading).combined(with: .opacity)
        )
    }

    // MARK: - Navigation

    private func push(_ noteId: String) {
        guard noteId != navPath.last else { return }
        goingBack = false
        navPath.append(noteId)
    }

    private func pop() {
        guard navPath.count > 1 else { return }
        goingBack = true
        navPath.removeLast()
    }

    private func popTo(index: Int) {
        guard index < navPath.count - 1 else { return }
        goingBack = true
        navPath = Array(navPath.prefix(index + 1))
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button(action: pop) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Back")
            .accessibilityLabel("Back")

            ForEach(Array(navPath.enumerated()), id: \.offset) { idx, id in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button { popTo(index: idx) } label: {
                    Text(titlesById[id] ?? "Note")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(idx == navPath.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(idx == navPath.count - 1)
                .accessibilityLabel("Go to \(titlesById[id] ?? "note")")
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "note.text")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No Note Selected")
                .font(DesignTokens.Typography.section)
                .foregroundStyle(.secondary)
            Text("Choose a note from the list.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Segmented control offering "All / Unfiled". Renders only when the parent
/// originally opened on `.all` or `.inbox` — for notebook views the chip
/// would be confusing.
private struct NotesScopeChipBar: View {
    @Binding var activeScope: NoteListScope

    var body: some View {
        HStack(spacing: 2) {
            chip(title: "All",     isActive: isAll)     { activeScope = .all }
            chip(title: "Unfiled", isActive: isInbox)   { activeScope = .inbox }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(DesignTokens.Palette.surfaceElevated)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var isAll: Bool {
        if case .all = activeScope { return true } else { return false }
    }
    private var isInbox: Bool {
        if case .inbox = activeScope { return true } else { return false }
    }

    @ViewBuilder
    private func chip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Stable hashable identifier for a `NoteListScope` so SwiftUI can `.id()`
/// the inner list and force the view model to rebuild when the chip toggles.
private struct NoteListScopeID: Hashable {
    let scope: NoteListScope

    func hash(into hasher: inout Hasher) {
        switch scope {
        case .all:                 hasher.combine("all")
        case .inbox:               hasher.combine("inbox")
        case .notebook(let id):    hasher.combine("notebook"); hasher.combine(id)
        }
    }

    static func == (lhs: NoteListScopeID, rhs: NoteListScopeID) -> Bool {
        switch (lhs.scope, rhs.scope) {
        case (.all, .all):                 return true
        case (.inbox, .inbox):             return true
        case (.notebook(let a), .notebook(let b)): return a == b
        default: return false
        }
    }
}
